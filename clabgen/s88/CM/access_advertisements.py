from __future__ import annotations

import ipaddress
import json
import re
import shlex
from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else []


def _enabled(scope: Dict[str, Any]) -> bool:
    # FS-310-HDS-010-SDS-010-SMS-110: fail-closed — must explicitly be True,
    # not merely non-False. Only explicit boolean True enables.
    return scope.get("enabled") is True


def _interface(scope: Dict[str, Any], eth_map: Dict[str, str]) -> str | None:
    logical = scope.get("bindInterface") or scope.get("interface")
    if not isinstance(logical, str) or not logical:
        raise ValueError("access advertisement scope requires bindInterface")
    runtime = eth_map.get(logical)
    if not isinstance(runtime, str) or not runtime:
        return None
    return runtime


def _address(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"access DHCPv4 advertisement requires {field}")
    try:
        return str(ipaddress.ip_address(value))
    except ValueError as exc:
        raise ValueError(f"invalid access DHCPv4 {field}: {value!r}") from exc


def _network(value: Any, field: str) -> ipaddress.IPv4Network:
    if not isinstance(value, str) or not value:
        raise ValueError(f"access DHCPv4 advertisement requires {field}")
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError as exc:
        raise ValueError(f"invalid access DHCPv4 {field}: {value!r}") from exc
    if network.version != 4:
        raise ValueError(f"access DHCPv4 {field} must be IPv4")
    return network


def _network6(value: Any, field: str) -> ipaddress.IPv6Network:
    if not isinstance(value, str) or not value:
        raise ValueError(f"access DHCPv6 advertisement requires {field}")
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError as exc:
        raise ValueError(f"invalid access DHCPv6 {field}: {value!r}") from exc
    if network.version != 6:
        raise ValueError(f"access DHCPv6 {field} must be IPv6")
    return network


def _pool_string(scope: Dict[str, Any], family: str) -> str:
    pool = scope.get("pool")
    if isinstance(pool, str) and pool:
        parts = [part.strip() for part in pool.split("-", maxsplit=1)]
    elif isinstance(pool, dict):
        parts = [pool.get("start"), pool.get("end")]
    else:
        parts = []
    if len(parts) != 2 or not all(isinstance(part, str) and part for part in parts):
        raise ValueError(
            f"access DHCP{family} advertisement requires pool.start and pool.end"
        )
    try:
        addresses = [ipaddress.ip_address(part) for part in parts]
    except ValueError as exc:
        raise ValueError(f"invalid access DHCP{family} pool") from exc
    expected_version = 4 if family == "v4" else 6
    if any(address.version != expected_version for address in addresses):
        raise ValueError(f"access DHCP{family} pool has the wrong address family")
    return f"{addresses[0]} - {addresses[1]}"


def protected_reservation_source(
    scope: Dict[str, Any], family: str
) -> str | None:
    source = scope.get("reservationSource")
    if source is None:
        return None
    if not isinstance(source, dict):
        raise ValueError(
            "access reservationSource must be an opaque protected-source record"
        )
    allowed_fields = {
        "schema",
        "sourceClass",
        "sourceFile",
        "family",
        "namePublication",
        "binderSourceAudit",
        "upstreamBehaviorRef",
    }
    if set(source) - allowed_fields:
        raise ValueError("diagnostic.protected-reservation-identity-leaked")
    if source.get("schema") != "gamp-protected-reservation-set-v1":
        raise ValueError("diagnostic.runtime-reservation-source-schema-invalid")
    if source.get("sourceClass") != "protected":
        raise ValueError("diagnostic.protected-reservation-identity-leaked")
    if source.get("family") not in {None, family}:
        raise ValueError("diagnostic.runtime-reservation-source-family-invalid")
    source_file = source.get("sourceFile")
    if (
        not isinstance(source_file, str)
        or not source_file.startswith("/run/secrets/")
        or source_file == "/run/secrets/"
        or "/../" in source_file
    ):
        raise ValueError("diagnostic.runtime-reservation-source-path-invalid")
    reservations = scope.get("reservations", [])
    if not isinstance(reservations, list) or reservations:
        raise ValueError("diagnostic.runtime-reservation-source-conflict")
    _protected_name_publication(
        source,
        family,
        _scope_id(scope, "v4" if family == "ipv4" else "v6"),
    )
    return source_file


def _protected_name_publication(
    source: Dict[str, Any], family: str, scope_id: str
) -> Dict[str, Any] | None:
    publication = source.get("namePublication")
    if publication is None:
        return None
    if not isinstance(publication, dict):
        raise ValueError("diagnostic.protected-reservation-name-publication-invalid")
    allowed_fields = {
        "namespace",
        "ownerScope",
        "requesterScopes",
        "recordClasses",
        "fallbackBehavior",
        "publicationDenialDiagnostic",
        "source",
        "sourceFamily",
    }
    if set(publication) - allowed_fields:
        raise ValueError(
            "diagnostic.protected-reservation-name-publication-field-invalid"
        )
    namespace = publication.get("namespace")
    owner_scope = publication.get("ownerScope")
    requester_scopes = publication.get("requesterScopes")
    record_classes = publication.get("recordClasses")
    if (
        not isinstance(namespace, str)
        or not re.fullmatch(r"(?:[A-Za-z0-9][A-Za-z0-9_-]*\.)+", namespace)
        or owner_scope != scope_id
        or not isinstance(requester_scopes, list)
        or not requester_scopes
        or not all(isinstance(item, str) and item for item in requester_scopes)
        or owner_scope not in requester_scopes
        or "*" in requester_scopes
    ):
        raise ValueError("diagnostic.protected-reservation-name-scope-invalid")
    if (
        not isinstance(record_classes, list)
        or not record_classes
        or len(record_classes) != len(set(record_classes))
        or not set(record_classes).issubset({"A", "AAAA", "PTR"})
    ):
        raise ValueError("diagnostic.protected-reservation-name-record-class-invalid")
    if (
        publication.get("source") != "protected-reservation-set"
        or publication.get("sourceFamily") != family
        or publication.get("fallbackBehavior") != "local-only"
        or not isinstance(publication.get("publicationDenialDiagnostic"), str)
        or not publication["publicationDenialDiagnostic"]
    ):
        raise ValueError("diagnostic.protected-reservation-name-policy-invalid")
    return publication


def _safe_stem(value: str) -> str:
    return value.replace("/", "-").replace(":", "-").replace(" ", "-")


def _dhcp4_config(scope: Dict[str, Any], ifname: str) -> str:
    subnet = _network(scope.get("subnet"), "subnet")
    pool = _dict(scope.get("pool"))
    start = _address(pool.get("start"), "pool.start")
    end = _address(pool.get("end"), "pool.end")
    router = _address(
        scope.get("routerAddress") or scope.get("router"),
        "routerAddress",
    )
    dns_servers = scope.get("dnsServers")
    if not isinstance(dns_servers, list) or not dns_servers:
        raise ValueError(
            "access DHCPv4 advertisement requires dnsServers with at least one server"
        )
    resolved_dns_servers: List[str] = []
    for item in dns_servers:
        resolved_dns_servers.append(_address(item, "dnsServers[]"))
    dns = " ".join(resolved_dns_servers)
    domain = scope.get("domain")
    if not isinstance(domain, str) or not domain:
        raise ValueError("access DHCPv4 advertisement requires domain")

    return "\n".join(
        [
            f"interface {ifname}",
            f"start {start}",
            f"end {end}",
            f"option subnet {subnet.netmask}",
            f"option router {router}",
            f"option dns {dns}",
            f"option domain {domain}",
            "lease 3600",
            f"lease_file /run/udhcpd.{ifname}.leases",
            f"pidfile /run/udhcpd.{ifname}.pid",
            "",
        ]
    )


def _dhcp4_command(scope: Dict[str, Any], ifname: str) -> str:
    source_file = protected_reservation_source(scope, "ipv4")
    if source_file is not None:
        return _kea_command(scope, ifname, "ipv4", source_file)
    config_path = f"/run/udhcpd.{ifname}.conf"
    lease_path = f"/run/udhcpd.{ifname}.leases"
    config = _dhcp4_config(scope, ifname)
    return "\n".join(
        [
            "command -v udhcpd >/dev/null || { echo 'missing udhcpd' >&2; exit 1; }",
            "mkdir -p /run",
            f"cat > {config_path} <<'EOF'",
            config,
            "EOF",
            f"touch {lease_path}",
            f"test ! -s /run/udhcpd.{ifname}.pid || kill $(cat /run/udhcpd.{ifname}.pid) 2>/dev/null || true",
            f"udhcpd {config_path}",
        ]
    )


def _scope_id(scope: Dict[str, Any], family: str) -> str:
    value = scope.get("id") or scope.get("scopeId")
    if not isinstance(value, str) or not value:
        raise ValueError(f"access DHCP{family} advertisement requires id")
    return value


def _dns_servers(scope: Dict[str, Any], version: int) -> List[str]:
    values = scope.get("dnsServers")
    if not isinstance(values, list) or not values:
        raise ValueError("access DHCP advertisement requires dnsServers")
    result: List[str] = []
    for value in values:
        try:
            address = ipaddress.ip_address(value)
        except (TypeError, ValueError) as exc:
            raise ValueError("invalid access DHCP dnsServers[]") from exc
        if address.version != version:
            raise ValueError("access DHCP dnsServers[] has the wrong address family")
        result.append(str(address))
    return result


def _domain(scope: Dict[str, Any]) -> str:
    value = scope.get("domain")
    if not isinstance(value, str) or not value:
        raise ValueError("access DHCP advertisement requires domain")
    return value


def _kea_template(
    scope: Dict[str, Any], ifname: str, family: str
) -> Dict[str, Any]:
    pool = _pool_string(scope, "v4" if family == "ipv4" else "v6")
    if family == "ipv4":
        subnet = _network(scope.get("subnet"), "subnet")
        router = _address(
            scope.get("routerAddress") or scope.get("router"), "routerAddress"
        )
        return {
            "Dhcp4": {
                "interfaces-config": {
                    "interfaces": [ifname],
                    "service-sockets-max-retries": 30,
                    "service-sockets-retry-wait-time": 1000,
                },
                "lease-database": {
                    "type": "memfile",
                    "persist": True,
                    "name": f"/run/kea/{ifname}-dhcp4.leases",
                },
                "subnet4": [
                    {
                        "id": 1,
                        "subnet": str(subnet),
                        "pools": [{"pool": pool}],
                        "option-data": [
                            {"name": "routers", "data": router},
                            {
                                "name": "domain-name-servers",
                                "data": ", ".join(_dns_servers(scope, 4)),
                            },
                            {"name": "domain-name", "data": _domain(scope)},
                        ],
                        "reservations": [],
                    }
                ],
            }
        }
    subnet6 = _network6(scope.get("subnet"), "subnet")
    return {
        "Dhcp6": {
            "interfaces-config": {
                "interfaces": [ifname],
                "service-sockets-max-retries": 30,
                "service-sockets-retry-wait-time": 1000,
            },
            "lease-database": {
                "type": "memfile",
                "persist": True,
                "name": f"/run/kea/{ifname}-dhcp6.leases",
            },
            "subnet6": [
                {
                    "id": 1,
                    "interface": ifname,
                    "subnet": str(subnet6),
                    "pools": [{"pool": pool}],
                    "option-data": [
                        {
                            "name": "dns-servers",
                            "data": ", ".join(_dns_servers(scope, 6)),
                        },
                        {"name": "domain-search", "data": _domain(scope)},
                    ],
                    "reservations": [],
                }
            ],
        }
    }


def _kea_reconcile_script(
    ifname: str,
    family: str,
    daemon: str,
    config_path: str,
    pid_path: str,
    log_path: str,
) -> str:
    address_family = "-4" if family == "ipv4" else "-6"
    socket_port = "67" if family == "ipv4" else "547"
    quoted_ifname = shlex.quote(ifname)
    return "\n".join(
        [
            "#!/bin/sh",
            "set -eu",
            "kea_interface_attempt=0",
            f"until ip link show up dev {quoted_ifname} >/dev/null 2>&1 && "
            f"ip {address_family} -o address show dev {quoted_ifname} "
            "scope global | grep -q .; do",
            "  kea_interface_attempt=$((kea_interface_attempt + 1))",
            "  test \"${kea_interface_attempt}\" -lt 60 || "
            f"{{ echo '{daemon} interface did not become ready' >&2; exit 1; }}",
            "  sleep 1",
            "done",
            f"test ! -s {pid_path} || kill $(cat {pid_path}) 2>/dev/null || true",
            "sleep 1",
            f"{daemon} -d -c {config_path} >{log_path} 2>&1 &",
            f"echo $! > {pid_path}",
            "kea_socket_attempt=0",
            f"until kill -0 $(cat {pid_path}) 2>/dev/null && "
            f"ss -H -lun {shlex.quote(f'sport = :{socket_port}')} | grep -q .; do",
            "  kea_socket_attempt=$((kea_socket_attempt + 1))",
            "  test \"${kea_socket_attempt}\" -lt 30 || "
            f"{{ echo '{daemon} did not open its service socket' >&2; exit 1; }}",
            "  sleep 1",
            "done",
            "",
        ]
    )


def _kea_command(
    scope: Dict[str, Any], ifname: str, family: str, source_file: str
) -> str:
    suffix = "4" if family == "ipv4" else "6"
    template_path = f"/run/kea/{ifname}-dhcp{suffix}-template.json"
    config_path = f"/run/kea/{ifname}-dhcp{suffix}.json"
    pid_path = f"/run/kea/{ifname}-dhcp{suffix}.pid"
    log_path = f"/run/kea/{ifname}-dhcp{suffix}.log"
    reconcile_path = f"/run/kea/reconcile-{ifname}-dhcp{suffix}.sh"
    template = json.dumps(
        _kea_template(scope, ifname, family), sort_keys=True, separators=(",", ":")
    )
    scope_id = _scope_id(scope, "v4" if family == "ipv4" else "v6")
    publication = _protected_name_publication(
        _dict(scope.get("reservationSource")), family, scope_id
    )
    materializer_args = [
        "clab-protected-reservation-materializer",
        "--family",
        family,
        "--scope",
        scope_id,
        "--subnet",
        str(scope.get("subnet")),
        "--pool",
        _pool_string(scope, "v4" if family == "ipv4" else "v6"),
        "--source",
        source_file,
        "--template",
        template_path,
        "--output",
        config_path,
    ]
    if publication is not None:
        materializer_args.extend(
            [
                "--dns-output",
                f"/run/protected-reservation-dns/{_safe_stem(scope_id)}.conf",
                "--dns-namespace",
                publication["namespace"],
                "--dns-group",
                "unbound",
            ]
        )
        for record_class in publication["recordClasses"]:
            materializer_args.extend(["--dns-record-class", record_class])
    materialize = " ".join(shlex.quote(value) for value in materializer_args)
    daemon = f"kea-dhcp{suffix}"
    reconcile = _kea_reconcile_script(
        ifname,
        family,
        daemon,
        config_path,
        pid_path,
        log_path,
    )
    return "\n".join(
        [
            f"command -v {daemon} >/dev/null || {{ echo 'missing {daemon}' >&2; exit 1; }}",
            "command -v ss >/dev/null || { echo 'missing ss' >&2; exit 1; }",
            "command -v clab-protected-reservation-materializer >/dev/null || "
            "{ echo 'missing protected reservation materializer' >&2; exit 1; }",
            f"test -r {shlex.quote(source_file)} || "
            "{ echo 'protected reservation source unavailable' >&2; exit 1; }",
            # Kea DHCPv6 creates its server identifier below /var/lib/kea even
            # when the lease database itself is runtime-local. Containerlab's
            # minimal image does not create that directory for us.
            "install -d -m 0700 /run/kea /var/lib/kea",
            f"cat > {template_path} <<'EOF'",
            template,
            "EOF",
            materialize,
            # Kea sockets are bound to an interface instance. Containerlab may
            # replace that instance after node-init, so startup is reconciled by
            # the host deployer only after `containerlab deploy` has completed.
            f"cat > {reconcile_path} <<'EOF'",
            reconcile,
            "EOF",
            f"chmod 0700 {reconcile_path}",
        ]
    )


def _dhcp6_command(scope: Dict[str, Any], ifname: str) -> str:
    source_file = protected_reservation_source(scope, "ipv6")
    if source_file is None:
        raise ValueError(
            "access DHCPv6 is only supported with a protected reservationSource"
        )
    return _kea_command(scope, ifname, "ipv6", source_file)


def _ipv6_ra_prefixes(scope: Dict[str, Any]) -> List[str]:
    prefixes = _list(scope.get("prefixes"))
    if not prefixes:
        router_interface = _dict(scope.get("routerInterface"))
        prefixes = _list(router_interface.get("advertisedPrefixes6"))
    if not prefixes:
        raise ValueError("access IPv6 RA advertisement requires prefixes")

    rendered: List[str] = []
    for raw_prefix in prefixes:
        if not isinstance(raw_prefix, str) or not raw_prefix:
            raise ValueError("access IPv6 RA prefix must be a string")
        try:
            prefix = ipaddress.ip_network(raw_prefix, strict=False)
        except ValueError as exc:
            raise ValueError(f"invalid access IPv6 RA prefix: {raw_prefix!r}") from exc
        if prefix.version != 6:
            raise ValueError("access IPv6 RA prefix must be IPv6")
        rendered.append(str(prefix))
    return rendered


def _ipv6_ra_command(scope: Dict[str, Any], ifname: str) -> str:
    prefixes = _ipv6_ra_prefixes(scope)
    commands = [
        "command -v vtysh >/dev/null || { echo 'missing vtysh' >&2; exit 1; }",
        f"sysctl -qw net.ipv6.conf.{ifname}.forwarding=1 net.ipv6.conf.{ifname}.disable_ipv6=0 || true",
        "mkdir -p /etc/frr /var/run/frr",
        "touch /etc/frr/vtysh.conf",
        "if ! pgrep -x zebra >/dev/null 2>&1; then /usr/lib/frr/zebra -d -F traditional -A 127.0.0.1 || true; sleep 1; fi",
        "vtysh -c 'configure terminal' "
        f"-c 'interface {ifname}' "
        "-c 'no ipv6 nd suppress-ra' "
        "-c 'ipv6 nd ra-interval 30'",
    ]
    if scope.get("managed") is True:
        commands.append(
            "vtysh -c 'configure terminal' "
            f"-c 'interface {ifname}' -c 'ipv6 nd managed-config-flag'"
        )
    if scope.get("otherConfig") is True:
        commands.append(
            "vtysh -c 'configure terminal' "
            f"-c 'interface {ifname}' -c 'ipv6 nd other-config-flag'"
        )
    prefix_flags: List[str] = []
    if scope.get("onLink") is False:
        prefix_flags.append("off-link")
    if scope.get("autonomous") is False:
        prefix_flags.append("no-autoconfig")
    suffix = f" {' '.join(prefix_flags)}" if prefix_flags else ""
    for prefix in prefixes:
        commands.append(
            "vtysh -c 'configure terminal' "
            f"-c 'interface {ifname}' "
            f"-c 'ipv6 nd prefix {prefix}{suffix}'"
        )
    return "\n".join(commands)


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    advertisements = _dict(node.get("advertisements"))
    cmds: List[str] = []

    for scope in _list(advertisements.get("dhcp4")):
        if not isinstance(scope, dict) or not _enabled(scope):
            continue
        ifname = _interface(scope, eth_map)
        if ifname is None:
            continue
        cmds.append(_sh(_dhcp4_command(scope, ifname)))

    for scope in _list(advertisements.get("dhcpv6")):
        if not isinstance(scope, dict) or not _enabled(scope):
            continue
        ifname = _interface(scope, eth_map)
        if ifname is None:
            continue
        cmds.append(_sh(_dhcp6_command(scope, ifname)))

    for scope in _list(advertisements.get("ipv6Ra")):
        if not isinstance(scope, dict) or not _enabled(scope):
            continue
        ifname = _interface(scope, eth_map)
        if ifname is None:
            continue
        cmds.append(_sh(_ipv6_ra_command(scope, ifname)))

    return cmds
