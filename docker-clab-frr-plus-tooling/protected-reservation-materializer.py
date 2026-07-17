#!/usr/bin/env python3
"""Materialize one protected reservation set into a runtime-local Kea config."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any


DIAGNOSTIC = "diagnostic.runtime-reservation-secret-record-invalid"
SCHEMA_FIELDS = {"id", "scope", "ipv4", "ipv6", "hostname"}
HOSTNAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAC = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
IID = re.compile(r"^[0-9A-Fa-f]{16}$")
DUID = re.compile(r"^[0-9A-Fa-f]{4,260}$")


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


def reservation_pool(
    family: str, subnet: object, pool_text: str
) -> tuple[int, int]:
    require(isinstance(subnet, (ipaddress.IPv4Network, ipaddress.IPv6Network)))
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


def materialize_records(
    family: str, scope: str, subnet_text: str, pool_text: str, source_path: Path
) -> tuple[list[dict[str, Any]], bool]:
    require(family in {"ipv4", "ipv6"} and scope != "")
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
        require(isinstance(record, dict) and set(record).issubset(SCHEMA_FIELDS))
        handle = record.get("id")
        require(isinstance(handle, str) and handle != "" and handle not in ids)
        ids.add(handle)
        require(record.get("scope") == scope)
        hostname = record.get("hostname")
        require(
            hostname is None
            or (
                isinstance(hostname, str)
                and HOSTNAME.fullmatch(hostname) is not None
            )
        )

        if family == "ipv4":
            identity = record.get("ipv4")
            require(isinstance(identity, dict))
            require(set(identity) == {"address", "mac-address"})
            address = ipaddress.IPv4Address(identity["address"])
            require(address in network)
            mac = identity["mac-address"]
            require(isinstance(mac, str) and MAC.fullmatch(mac) is not None)
            normalized_identity = mac.lower()
            emitted_record: dict[str, Any] = {
                "hw-address": normalized_identity,
                "ip-address": str(address),
            }
        else:
            identity = record.get("ipv6")
            require(isinstance(identity, dict))
            require(
                set(identity)
                == {"address", "iid", "iid-stability", "duid", "iaid"}
            )
            address = ipaddress.IPv6Address(identity["address"])
            require(address in network)
            iid = normalized_iid(identity["iid"])
            require(identity["iid-stability"] == "stable")
            require((int(address) & ((1 << 64) - 1)) == iid)
            normalized_identity = normalized_duid(identity["duid"])
            iaid = identity["iaid"]
            require(
                isinstance(iaid, int)
                and not isinstance(iaid, bool)
                and 0 <= iaid <= 0xFFFFFFFF
            )
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

    return (emitted, has_out_of_pool)


def insert_reservations(
    config: dict[str, Any],
    family: str,
    runtime_records: list[dict[str, Any]],
    has_out_of_pool: bool,
) -> dict[str, Any]:
    if family == "ipv4":
        subnets = config["Dhcp4"]["subnet4"]
        identity_key = "hw-address"
        address_key = "ip-address"
    else:
        subnets = config["Dhcp6"]["subnet6"]
        identity_key = "duid"
        address_key = "ip-addresses"

    require(isinstance(subnets, list) and len(subnets) == 1)
    existing = subnets[0].get("reservations", [])
    require(isinstance(existing, list) and not existing)
    require(
        len({record[identity_key] for record in runtime_records})
        == len(runtime_records)
    )
    if family == "ipv4":
        reservation_addresses = [record[address_key] for record in runtime_records]
    else:
        reservation_addresses = [
            record[address_key][0] for record in runtime_records
        ]
    require(len(set(reservation_addresses)) == len(runtime_records))
    subnets[0]["reservations"] = runtime_records
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--family", choices=("ipv4", "ipv6"), required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--subnet", required=True)
    parser.add_argument("--pool", required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with args.template.open("r", encoding="utf-8") as template_handle:
        config = json.load(template_handle)
    records, has_out_of_pool = materialize_records(
        args.family, args.scope, args.subnet, args.pool, args.source
    )
    atomic_write(
        args.output,
        insert_reservations(config, args.family, records, has_out_of_pool),
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(
            f"{DIAGNOSTIC}: protected reservation set or Kea template rejected",
            file=sys.stderr,
        )
        raise SystemExit(1)
