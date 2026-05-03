from __future__ import annotations

from typing import Any, Dict, List
import ipaddress


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes = iface.get("routes")
    if routes is None:
        routes = {}
    if not isinstance(routes, dict):
        raise ValueError("interface.routes must be an object")

    ipv4 = routes.get("ipv4", [])
    ipv6 = routes.get("ipv6", [])

    if not isinstance(ipv4, list):
        raise ValueError("interface.routes.ipv4 must be an array")

    if not isinstance(ipv6, list):
        raise ValueError("interface.routes.ipv6 must be an array")

    ipv4_routes: List[Dict[str, Any]] = []
    for route in ipv4:
        if isinstance(route, dict):
            ipv4_routes.append(dict(route))

    ipv6_routes: List[Dict[str, Any]] = []
    for route in ipv6:
        if isinstance(route, dict):
            ipv6_routes.append(dict(route))

    return {
        "ipv4": ipv4_routes,
        "ipv6": ipv6_routes,
    }


def _dst(route: Dict[str, Any]) -> str | None:
    return route.get("dst")


def _via4(route: Dict[str, Any]) -> str | None:
    return route.get("via4")


def _via6(route: Dict[str, Any]) -> str | None:
    return route.get("via6")


def _normalize_prefix(dst: str) -> str:
    if not isinstance(dst, str):
        return dst

    if "." in dst and "/" in dst:
        ip, prefix = dst.split("/", 1)
        try:
            prefix_length = int(prefix)
            if prefix_length > 32:
                return f"{ip}/32"
        except Exception:
            pass

    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except Exception:
        return dst


def _host_prefix(value: str, family: int) -> str | None:
    try:
        ip = ipaddress.ip_address(value)
    except Exception:
        return None

    if ip.version != family:
        return None

    prefix = 32 if family == 4 else 128
    return f"{ip}/{prefix}"
