from __future__ import annotations

import ipaddress
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
    for prefix in prefixes:
        commands.append(
            "vtysh -c 'configure terminal' "
            f"-c 'interface {ifname}' "
            f"-c 'ipv6 nd prefix {prefix}'"
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

    for scope in _list(advertisements.get("ipv6Ra")):
        if not isinstance(scope, dict) or not _enabled(scope):
            continue
        ifname = _interface(scope, eth_map)
        if ifname is None:
            continue
        cmds.append(_sh(_ipv6_ra_command(scope, ifname)))

    return cmds
