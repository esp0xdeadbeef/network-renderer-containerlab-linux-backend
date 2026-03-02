from typing import Dict, Any, List
import ipaddress


def _ipv4_interface_network(addr_cidr: str) -> ipaddress.IPv4Network:
    return ipaddress.IPv4Interface(addr_cidr).network


def _ipv6_interface_network(addr_cidr: str) -> ipaddress.IPv6Network:
    return ipaddress.IPv6Interface(addr_cidr).network


def _collect_ipv4_connected_networks(node: Dict[str, Any]) -> List[ipaddress.IPv4Network]:
    nets: List[ipaddress.IPv4Network] = []
    for iface in node.get("interfaces", {}).values():
        for addr in iface.get("addresses4", []):
            try:
                nets.append(_ipv4_interface_network(addr))
            except Exception:
                pass
    return nets


def _collect_ipv6_connected_networks(node: Dict[str, Any]) -> List[ipaddress.IPv6Network]:
    nets: List[ipaddress.IPv6Network] = []
    for iface in node.get("interfaces", {}).values():
        for addr in iface.get("addresses6", []):
            try:
                nets.append(_ipv6_interface_network(addr))
            except Exception:
                pass
    return nets


def _is_valid_ipv4_nexthop(via: str, connected: List[ipaddress.IPv4Network]) -> bool:
    try:
        ip = ipaddress.IPv4Address(via)
    except Exception:
        return False

    if ip.is_multicast or ip.is_unspecified:
        return False

    for net in connected:
        if ip in net:
            return True

    return False


def _is_valid_ipv6_nexthop(via: str, connected: List[ipaddress.IPv6Network]) -> bool:
    try:
        ip = ipaddress.IPv6Address(via)
    except Exception:
        return False

    if ip.is_multicast or ip.is_unspecified:
        return False

    for net in connected:
        if ip in net:
            return True

    return False


def _route4(dst: str, via: str | None, dev: str, connected: List[ipaddress.IPv4Network]) -> str:
    if dst == "0.0.0.0/0":
        if not via or not _is_valid_ipv4_nexthop(via, connected):
            return ""
        return f"ip route replace default via {via} dev {dev}"

    if via:
        if not _is_valid_ipv4_nexthop(via, connected):
            return ""
        return f"ip route replace {dst} via {via} dev {dev}"

    return f"ip route replace {dst} dev {dev}"


def _route6(dst: str, via: str | None, dev: str, connected: List[ipaddress.IPv6Network]) -> str:
    if dst == "::/0":
        if not via or not _is_valid_ipv6_nexthop(via, connected):
            return ""
        return f"ip -6 route replace default via {via} dev {dev}"

    if via:
        if not _is_valid_ipv6_nexthop(via, connected):
            return ""
        return f"ip -6 route replace {dst} via {via} dev {dev}"

    return f"ip -6 route replace {dst} dev {dev}"


def render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    connected_v4 = _collect_ipv4_connected_networks(node)
    connected_v6 = _collect_ipv6_connected_networks(node)

    interfaces = node.get("interfaces", {})

    for logical_if, iface in interfaces.items():
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        for r in iface.get("routes4", []):
            dst = r.get("dst")
            via = r.get("via4")
            if dst:
                cmd = _route4(dst, via, eth, connected_v4)
                if cmd:
                    cmds.append(cmd)

        for r in iface.get("routes6", []):
            dst = r.get("dst")
            via = r.get("via6")
            if dst:
                cmd = _route6(dst, via, eth, connected_v6)
                if cmd:
                    cmds.append(cmd)

    return cmds
