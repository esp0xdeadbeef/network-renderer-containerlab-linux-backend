from __future__ import annotations

from typing import Dict, Any, List, Set
import ipaddress


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


def render_default_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: Set[str] = set()

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
