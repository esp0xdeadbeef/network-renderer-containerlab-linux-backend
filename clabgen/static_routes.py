# ./clabgen/static_routes.py
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


def _connected_prefixes(node: Dict[str, Any]) -> tuple[Set[str], Set[str]]:
    connected4: Set[str] = set()
    connected6: Set[str] = set()

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


def render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: Set[str] = set()

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
            if r.get("proto") == "connected":
                continue
            if dst in connected6:
                continue

            cmd = f"ip -6 route replace {dst} via {via} dev eth{eth} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds
