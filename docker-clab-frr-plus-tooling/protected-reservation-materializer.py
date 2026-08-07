#!/usr/bin/env python3
"""Materialize one protected reservation set into a runtime-local Kea config.

GAMP-ID: FS-560-HDS-010-SDS-010-SMS-050
GAMP-SCOPE: software-module-construction

Owning implementation artifact for protected reservation name materialization
(SMS-050).  Consumes the schema-valid canonical publication record via the
--dns-* arguments and materializes platform-native A, AAAA, and PTR local data
for Unbound at runtime.

Predicate coverage:
  001 — Bind to namespace owner, requester scopes, record classes, pub behavior
  002 — Absent/disabled publication yields zero DNS records
  003 — Opaque protected source reference preservation
  004 — Derived source kind + family from enclosing reservation source
  005 — Runtime-only A/AAAA/PTR materialization
  006 — One PTR per unique IPv4/IPv6 address
  007 — Address-set publication: group by namespace owner + hostname
  008 — Per-reservation identity preservation
  009 — Local authoritative boundary (no upstream fallthrough)
  010 — Reservation-to-Kea + reservation-to-DNS identity
  011 — Equivalent NixOS and CLAB semantics
  012 — Local publication independent from recursion/egress
  013 — Fail-closed with redacted diagnostics
"""

from __future__ import annotations

import argparse
import grp
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any


DIAGNOSTIC = "diagnostic.runtime-reservation-secret-record-invalid"
PUBLICATION_HOSTNAME_MISSING = "diagnostic.protected-reservation-name-publication-hostname-missing"
CROSS_IDENTITY_MISMATCH = "diagnostic.protected-reservation-cross-identity-mismatch"
SCHEMA_FIELDS = {"id", "scope", "ipv4", "ipv6", "hostname"}
HOSTNAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAC = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
IID = re.compile(r"^[0-9A-Fa-f]{16}$")
DUID = re.compile(r"^[0-9A-Fa-f]{4,260}$")
DNS_RECORD_CLASSES = {"A", "AAAA", "PTR"}
DNS_NAMESPACE = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9_-]*\.)+$")


class ReservationContractError(Exception):
    """A protected source failed the redacted runtime contract."""


def require(condition: bool) -> None:
    if not condition:
        raise ReservationContractError


def normalized_iid(value: object) -> int:
    require(isinstance(value, str))
    compact = value.replace(":", "").replace("-", "")
    require(IID.fullmatch(compact) is not None)
    return int(compact, 16)


def normalized_duid(value: object) -> str:
    require(isinstance(value, str))
    compact = value.replace(":", "").replace("-", "")
    require(len(compact) % 2 == 0 and DUID.fullmatch(compact) is not None)
    return ":".join(
        compact[index : index + 2].lower() for index in range(0, len(compact), 2)
    )


def reservation_pool(family: str, subnet: object, pool_text: str) -> tuple[int, int]:
    require(isinstance(subnet, (ipaddress.IPv4Network, ipaddress.IPv6Network)))
    require(isinstance(pool_text, str))
    bounds = [value.strip() for value in pool_text.split("-", maxsplit=1)]
    require(len(bounds) == 2 and all(bounds))
    start = ipaddress.ip_address(bounds[0])
    end = ipaddress.ip_address(bounds[1])
    require(start.version == subnet.version and end.version == subnet.version)
    require(start in subnet and end in subnet and int(start) <= int(end))
    require(
        (family == "ipv4" and start.version == 4)
        or (family == "ipv6" and start.version == 6)
    )
    return (int(start), int(end))


def validated_ipv4_identity(value: object) -> tuple[ipaddress.IPv4Address, str]:
    require(isinstance(value, dict))
    require(set(value) == {"address", "mac-address"})
    address = ipaddress.IPv4Address(value["address"])
    mac = value["mac-address"]
    require(isinstance(mac, str) and MAC.fullmatch(mac) is not None)
    return (address, mac.lower())


def validated_ipv6_identity(value: object) -> tuple[ipaddress.IPv6Address, str]:
    require(isinstance(value, dict))
    require(set(value) == {"address", "iid", "iid-stability", "duid", "iaid"})
    address = ipaddress.IPv6Address(value["address"])
    iid = normalized_iid(value["iid"])
    require(value["iid-stability"] == "stable")
    require((int(address) & ((1 << 64) - 1)) == iid)
    duid = normalized_duid(value["duid"])
    iaid = value["iaid"]
    require(
        isinstance(iaid, int)
        and not isinstance(iaid, bool)
        and 0 <= iaid <= 0xFFFFFFFF
    )
    return (address, duid)


def materialize_records(
    family: str, scope: str, subnet_text: str, pool_text: str, source_path: Path
) -> tuple[list[dict[str, Any]], bool, set[str]]:
    require(family in {"ipv4", "ipv6"})
    require(scope != "")
    network = ipaddress.ip_network(subnet_text, strict=True)
    require(
        (family == "ipv4" and network.version == 4)
        or (family == "ipv6" and network.version == 6)
    )
    pool_start, pool_end = reservation_pool(family, network, pool_text)

    with source_path.open("r", encoding="utf-8") as source_handle:
        source = json.load(source_handle)
    require(isinstance(source, list) and len(source) > 0)

    emitted: list[dict[str, Any]] = []
    ids: set[str] = set()
    identities: set[str] = set()
    addresses: set[str] = set()
    has_out_of_pool = False

    for record in source:
        require(isinstance(record, dict))
        require(set(record).issubset(SCHEMA_FIELDS))
        handle = record.get("id")
        require(isinstance(handle, str) and handle != "" and handle not in ids)
        ids.add(handle)
        require(record.get("scope") == scope)

        hostname = record.get("hostname")
        require(
            hostname is None
            or (isinstance(hostname, str) and HOSTNAME.fullmatch(hostname) is not None)
        )

        if family == "ipv4":
            address, normalized_identity = validated_ipv4_identity(record.get("ipv4"))
            require(address in network)
            emitted_record: dict[str, Any] = {
                "hw-address": normalized_identity,
                "ip-address": str(address),
            }
        else:
            address, normalized_identity = validated_ipv6_identity(record.get("ipv6"))
            require(address in network)
            emitted_record = {
                "duid": normalized_identity,
                "ip-addresses": [str(address)],
            }

        normalized_address = str(address)
        require(
            normalized_identity not in identities
            and normalized_address not in addresses
        )
        identities.add(normalized_identity)
        addresses.add(normalized_address)
        has_out_of_pool = has_out_of_pool or not (
            pool_start <= int(address) <= pool_end
        )
        if hostname is not None:
            emitted_record["hostname"] = hostname
        emitted.append(emitted_record)

    return (emitted, has_out_of_pool, ids)


def materialize_dns_lines(
    scope: str,
    namespace: str,
    record_classes: list[str],
    source_path: Path,
) -> tuple[list[str], set[str]]:
    require(scope != "")
    require(DNS_NAMESPACE.fullmatch(namespace) is not None)
    require(record_classes and set(record_classes).issubset(DNS_RECORD_CLASSES))
    require(len(record_classes) == len(set(record_classes)))

    with source_path.open("r", encoding="utf-8") as source_handle:
        source = json.load(source_handle)
    require(isinstance(source, list) and len(source) > 0)

    lines: list[str] = ["server:"]
    records_by_name: dict[str, dict[int, set[str]]] = {}
    address_owners: dict[str, str] = {}
    dns_ids: set[str] = set()
    for record in source:
        require(isinstance(record, dict))
        require(set(record).issubset(SCHEMA_FIELDS))
        require(record.get("scope") == scope)
        handle = record.get("id")
        require(isinstance(handle, str) and handle != "")
        hostname = record.get("hostname")
        if not isinstance(hostname, str) or not hostname:
            raise ReservationContractError(PUBLICATION_HOSTNAME_MISSING)
        dns_ids.add(handle)
        require(
            HOSTNAME.fullmatch(hostname) is not None
            and "." not in hostname
        )
        fqdn = f"{hostname}.{namespace}"
        normalized_fqdn = fqdn.lower()
        name_records = records_by_name.setdefault(
            normalized_fqdn,
            {4: set(), 6: set()},
        )

        # Determine per-address-family data before emitting.
        v4 = None
        v6 = None
        if record.get("ipv4") is not None:
            v4, _ = validated_ipv4_identity(record["ipv4"])
        if record.get("ipv6") is not None:
            v6, _ = validated_ipv6_identity(record["ipv6"])

        record_addresses: list[str] = []
        # Collect addresses based on requested record classes.
        if v4 is not None and "A" in record_classes:
            record_addresses.append(str(v4))
        if v6 is not None and "AAAA" in record_classes:
            record_addresses.append(str(v6))
        if "PTR" in record_classes and not record_addresses:
            if v4 is not None:
                record_addresses.append(str(v4))
            if v6 is not None:
                record_addresses.append(str(v6))
        require(record_addresses)

        # SMS-050 predicate 007: address-set publication allows distinct
        # reservation identities to contribute unique addresses to one
        # hostname. Identical name/address pairs are deduplicated, while one
        # address bound to multiple names is an ownership conflict.
        for address in record_addresses:
            parsed = ipaddress.ip_address(address)
            previous_owner = address_owners.get(address)
            require(previous_owner is None or previous_owner == normalized_fqdn)
            address_owners[address] = normalized_fqdn
            name_records[parsed.version].add(address)

    # Output is stable across protected-source input ordering. Keep all
    # addresses for one normalized owner together and emit one reverse binding
    # for every unique address.
    for normalized_fqdn in sorted(records_by_name):
        name_records = records_by_name[normalized_fqdn]
        for version, record_class in ((4, "A"), (6, "AAAA")):
            ordered_addresses = sorted(
                name_records[version],
                key=lambda value: int(ipaddress.ip_address(value)),
            )
            for address in ordered_addresses:
                if record_class in record_classes:
                    lines.append(
                        f'  local-data: "{normalized_fqdn} IN {record_class} {address}"'
                    )
                if "PTR" in record_classes:
                    lines.append(
                        f'  local-data-ptr: "{address} {normalized_fqdn}"'
                    )

    return (lines, dns_ids)


def insert_reservations(
    config: dict[str, Any],
    family: str,
    runtime_records: list[dict[str, Any]],
    has_out_of_pool: bool,
) -> dict[str, Any]:
    if family == "ipv4":
        subnets = config["Dhcp4"]["subnet4"]
        identity_key = "hw-address"
    else:
        subnets = config["Dhcp6"]["subnet6"]
        identity_key = "duid"

    def reservation_address(record: dict[str, Any]) -> str:
        if family == "ipv4":
            return record["ip-address"]
        return record["ip-addresses"][0]

    require(isinstance(subnets, list) and len(subnets) == 1)
    existing = subnets[0].get("reservations", [])
    require(isinstance(existing, list))
    combined = existing + runtime_records
    require(
        len({record[identity_key] for record in combined}) == len(combined)
        and len({reservation_address(record) for record in combined}) == len(combined)
    )
    subnets[0]["reservations"] = combined
    subnets[0]["reservations-in-subnet"] = True
    subnets[0]["reservations-out-of-pool"] = has_out_of_pool
    return config


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".kea-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output_handle:
            json.dump(value, output_handle, separators=(",", ":"), sort_keys=True)
            output_handle.write("\n")
            output_handle.flush()
            os.fsync(output_handle.fileno())
        os.replace(temporary_path, path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


def atomic_write_dns(path: Path, lines: list[str], group_name: str) -> None:
    group_id = grp.getgrnam(group_name).gr_gid
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    os.chmod(path.parent, 0o750)
    os.chown(path.parent, -1, group_id)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".dns-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o640)
        os.fchown(descriptor, -1, group_id)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output_handle:
            output_handle.write("\n".join(lines))
            output_handle.write("\n")
            output_handle.flush()
            os.fsync(output_handle.fileno())
        os.replace(temporary_path, path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--family", choices=("ipv4", "ipv6"), required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--subnet", required=True)
    parser.add_argument("--pool", required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dns-output", type=Path)
    parser.add_argument("--dns-namespace")
    parser.add_argument(
        "--dns-record-class", action="append", choices=tuple(sorted(DNS_RECORD_CLASSES))
    )
    parser.add_argument("--dns-group")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    dns_options = [args.dns_output, args.dns_namespace, args.dns_group]
    dns_enabled = any(value is not None for value in dns_options) or bool(
        args.dns_record_class
    )
    require(
        not dns_enabled
        or (
            args.source is not None
            and all(value is not None for value in dns_options)
            and bool(args.dns_record_class)
        )
    )
    with args.template.open("r", encoding="utf-8") as template_handle:
        config = json.load(template_handle)
    kea_ids: set[str] | None = None
    dns_ids: set[str] | None = None
    if args.source is not None:
        records, has_out_of_pool, kea_ids = materialize_records(
            args.family, args.scope, args.subnet, args.pool, args.source
        )
        config = insert_reservations(
            config, args.family, records, has_out_of_pool
        )
    if dns_enabled:
        dns_lines, dns_ids = materialize_dns_lines(
            args.scope,
            args.dns_namespace,
            args.dns_record_class,
            args.source,
        )
        atomic_write_dns(args.dns_output, dns_lines, args.dns_group)
    if kea_ids is not None and dns_ids is not None:
        require(kea_ids == dns_ids)
    atomic_write(args.output, config)


if __name__ == "__main__":
    try:
        main()
    except ReservationContractError as exc:
        msg = exc.args[0] if exc.args else DIAGNOSTIC
        print(
            f"{msg}: protected reservation set or Kea template rejected",
            file=sys.stderr,
        )
        raise SystemExit(1)
    except Exception:
        print(
            f"{DIAGNOSTIC}: protected reservation set or Kea template rejected",
            file=sys.stderr,
        )
        raise SystemExit(1)
