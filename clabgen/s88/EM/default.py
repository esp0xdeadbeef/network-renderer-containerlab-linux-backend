# ./clabgen/s88/EM/default.py
from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.s88.CM.base import render as render_cm


def _is_virtual_interface(iface: Dict[str, Any]) -> bool:
    return bool(
        iface.get("virtual") is True
        or iface.get("logical") is True
        or iface.get("type") == "logical"
        or iface.get("carrier") == "logical"
    )


def _canon_v6(addr: str) -> str:
    try:
        return str(ipaddress.IPv6Interface(addr))
    except Exception:
        return addr


def _is_network_address(addr: str) -> bool:
    try:
        iface = ipaddress.ip_interface(addr)
    except Exception:
        return False
    return iface.ip == iface.network.network_address


def _first_usable_host(addr: str) -> str:
    iface = ipaddress.ip_interface(addr)
    net = iface.network

    if isinstance(net, ipaddress.IPv4Network):
        if net.prefixlen >= 31:
            return str(iface)
        hosts = net.hosts()
        first = next(hosts)
        return f"{first}/{net.prefixlen}"

    if net.prefixlen >= 127:
        return str(iface)

    hosts = net.hosts()
    first = next(hosts)
    return f"{first}/{net.prefixlen}"


def _normalize_l3_addr(addr: str, iface: Dict[str, Any]) -> str:
    if not isinstance(addr, str) or not addr:
        return addr

    if iface.get("kind") == "tenant" and _is_network_address(addr):
        return _first_usable_host(addr)

    return addr


def _p2p_peer(addr: str) -> str | None:
    try:
        iface = ipaddress.ip_interface(addr)
        net = iface.network
        ip = iface.ip

        if isinstance(net, ipaddress.IPv4Network) and net.prefixlen == 31:
            a, b = list(net)
            peer = b if ip == a else a
            return str(peer)

        if isinstance(net, ipaddress.IPv6Network) and net.prefixlen == 127:
            a, b = list(net)
            peer = b if ip == a else a
            return str(peer)

    except Exception:
        return None

    return None


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes = iface.get("routes")
    if isinstance(routes, dict):
        return {
            "ipv4": list(routes.get("ipv4", [])),
            "ipv6": list(routes.get("ipv6", [])),
        }
    return {
        "ipv4": list(iface.get("routes4", [])),
        "ipv6": list(iface.get("routes6", [])),
    }


def _dst(r: Dict[str, Any]) -> str | None:
    return r.get("dst") or r.get("to")


def _via4(r: Dict[str, Any]) -> str | None:
    return r.get("via4") or r.get("via")


def _via6(r: Dict[str, Any]) -> str | None:
    return r.get("via6") or r.get("via")


def _normalize_prefix(dst: str) -> str:
    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except Exception:
        return dst


def _connected_prefixes(node: Dict[str, Any]) -> tuple[set[str], set[str]]:
    connected4: set[str] = set()
    connected6: set[str] = set()

    for iface in (node.get("interfaces", {}) or {}).values():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if isinstance(addr4, str) and addr4:
            try:
                connected4.add(str(ipaddress.ip_interface(addr4).network))
            except Exception:
                pass

        if isinstance(addr6, str) and addr6:
            try:
                connected6.add(str(ipaddress.ip_interface(addr6).network))
            except Exception:
                pass

    return connected4, connected6


def _peer_in_subnet(cidr: str | None) -> str | None:
    if not isinstance(cidr, str) or not cidr:
        return None

    iface = ipaddress.ip_interface(cidr)
    current = iface.ip

    if isinstance(iface.network, ipaddress.IPv4Network):
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 31:
            candidates = list(iface.network)
    else:
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 127:
            candidates = list(iface.network)

    for cand in candidates:
        if cand != current:
            return str(cand)

    return None


def _normalized_route_intents(node: Dict[str, Any]) -> List[Dict[str, Any]]:
    intents = node.get("route_intents")
    if isinstance(intents, list):
        return [r for r in intents if isinstance(r, dict)]
    return []


def _render_interfaces(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    interfaces = node.get("interfaces", {})

    for logical_if in sorted(interfaces.keys()):
        iface = interfaces[logical_if]
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        if _is_virtual_interface(iface):
            cmds.append(
                f"sh -c 'ip link show {eth} >/dev/null 2>&1 || ip link add {eth} type dummy'"
            )

        cmds.append(f"ip link set {eth} up")

    return cmds


def _render_addressing(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if isinstance(addr4, str) and addr4:
            addr4 = _normalize_l3_addr(addr4, iface)
            peer = _p2p_peer(addr4)
            if peer:
                ip = ipaddress.ip_interface(addr4).ip
                prefix = ipaddress.ip_interface(addr4).network.prefixlen
                cmds.append(
                    f"ip addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}"
                )
            else:
                cmds.append(f"ip addr replace {addr4} dev eth{eth}")

        if isinstance(addr6, str) and addr6:
            canon = _canon_v6(addr6)
            canon = _normalize_l3_addr(canon, iface)
            peer = _p2p_peer(canon)
            if peer:
                ip = ipaddress.ip_interface(canon).ip
                prefix = ipaddress.ip_interface(canon).network.prefixlen
                cmds.append(
                    f"ip -6 addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}"
                )
            else:
                cmds.append(f"ip -6 addr replace {canon} dev eth{eth}")

        if isinstance(ll6, str) and ll6:
            cmds.append(f"ip -6 addr replace {_canon_v6(ll6)} dev eth{eth}")

    return cmds


def _render_static_routes_from_intents(node: Dict[str, Any]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    connected4, connected6 = _connected_prefixes(node)

    for route in _normalized_route_intents(node):
        family = route.get("family")
        dst = route.get("dst")
        proto = route.get("proto")
        dev = route.get("dev")
        via4 = route.get("via4")
        via6 = route.get("via6")

        if not isinstance(dst, str) or not isinstance(dev, str):
            continue

        if family == "ipv4":
            if dst == "0.0.0.0/0" or not via4 or proto == "connected":
                continue
            dst = _normalize_prefix(dst)
            if dst in connected4:
                continue
            cmd = f"ip route replace {dst} via {via4} dev {dev} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

        if family == "ipv6":
            if dst == "::/0" or not via6 or proto == "connected":
                continue
            dst = _normalize_prefix(dst)
            if dst in connected6:
                continue
            cmd = f"ip -6 route replace {dst} via {via6} dev {dev} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds


def _render_default_routes_from_intents(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    dev_to_iface: Dict[str, Dict[str, Any]] = {}
    for ifname, eth in eth_map.items():
        dev_to_iface[f"eth{eth}"] = node.get("interfaces", {}).get(ifname, {})

    cmds: List[str] = []
    seen: set[str] = set()

    for route in _normalized_route_intents(node):
        family = route.get("family")
        dst = route.get("dst")
        proto = route.get("proto")
        dev = route.get("dev")
        via4 = route.get("via4")
        via6 = route.get("via6")

        if not isinstance(dev, str):
            continue

        iface = dev_to_iface.get(dev, {})

        if family == "ipv4" and dst == "0.0.0.0/0":
            via = via4
            if not via and proto == "uplink":
                via = _peer_in_subnet(iface.get("addr4"))
            if via:
                cmd = f"ip route replace default via {via} dev {dev} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

        if family == "ipv6" and dst == "::/0":
            via = via6
            if not via and proto == "uplink":
                via = _peer_in_subnet(iface.get("addr6"))
            if via:
                cmd = f"ip -6 route replace default via {via} dev {dev} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

    return cmds


def _render_static_routes_legacy(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()

    connected4, connected6 = _connected_prefixes(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for r in routes["ipv4"]:
            dst = _dst(r)
            via = _via4(r)
            if not dst or not via or dst == "0.0.0.0/0":
                continue
            dst = _normalize_prefix(dst)
            if r.get("proto") == "connected":
                continue
            if dst in connected4:
                continue

            cmd = f"ip route replace {dst} via {via} dev eth{eth} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

        for r in routes["ipv6"]:
            dst = _dst(r)
            via = _via6(r)
            if not dst or not via or dst == "::/0":
                continue
            dst = _normalize_prefix(dst)
            if r.get("proto") == "connected":
                continue
            if dst in connected6:
                continue

            cmd = f"ip -6 route replace {dst} via {via} dev eth{eth} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds


def _render_default_routes_legacy(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for r in routes["ipv4"]:
            if _dst(r) != "0.0.0.0/0":
                continue
            via = _via4(r)
            if not via and r.get("proto") == "uplink":
                via = _peer_in_subnet(iface.get("addr4"))
            if via:
                cmd = f"ip route replace default via {via} dev eth{eth} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

        for r in routes["ipv6"]:
            if _dst(r) != "::/0":
                continue
            via = _via6(r)
            if not via and r.get("proto") == "uplink":
                via = _peer_in_subnet(iface.get("addr6"))
            if via:
                cmd = f"ip -6 route replace default via {via} dev eth{eth} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

    return cmds


def _render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    intents = _normalized_route_intents(node)
    if intents:
        return _render_static_routes_from_intents(node)
    return _render_static_routes_legacy(node, eth_map)


def _render_default_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    intents = _normalized_route_intents(node)
    if intents:
        return _render_default_routes_from_intents(node, eth_map)
    return _render_default_routes_legacy(node, eth_map)


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> List[str]:
    cmds: List[str] = [
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
    ]

    cmds.extend(_render_interfaces(node_data, eth_map))
    cmds.extend(_render_addressing(node_data, eth_map))
    cmds.extend(_render_static_routes(node_data, eth_map))
    cmds.extend(_render_default_routes(node_data, eth_map))
    cmds.extend(render_cm(role, node_name))

    return cmds
