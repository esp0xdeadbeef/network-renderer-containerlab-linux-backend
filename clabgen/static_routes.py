from __future__ import annotations

from typing import Dict, Any, List
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


def _normalize_dst(dst: str) -> str:
    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except Exception:
        return dst


def _dst(r: Dict[str, Any]) -> str | None:
    dst = r.get("dst") or r.get("to")
    if not dst:
        return None
    return _normalize_dst(dst)


def _via4(r: Dict[str, Any]) -> str | None:
    return r.get("via4") or r.get("via")


def _via6(r: Dict[str, Any]) -> str | None:
    return r.get("via6") or r.get("via")


def render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

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
            if r.get("proto") == "connected":
                continue
            cmds.append(f"ip route replace {dst} via {via} dev eth{eth} onlink")

        for r in routes["ipv6"]:
            dst = _dst(r)
            via = _via6(r)
            if not dst or not via or dst == "::/0":
                continue
            if r.get("proto") == "connected":
                continue
            cmds.append(f"ip -6 route replace {dst} via {via} dev eth{eth} onlink")

    return cmds
