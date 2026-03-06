from __future__ import annotations

from typing import Dict, Any, List
import ipaddress


def _normalize(prefix: str) -> str:
    return str(ipaddress.ip_network(prefix, strict=False))


def render_connected_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for ifname, iface in node.get("interfaces", {}).items():
        if ifname not in eth_map:
            continue

        eth = f"eth{eth_map[ifname]}"

        routes = iface.get("routes", {})

        for r in routes.get("ipv4", []):
            if r.get("proto") != "connected":
                continue

            dst = r.get("dst")
            if not dst:
                continue

            net = ipaddress.ip_network(dst, strict=False)
            if net.prefixlen == net.max_prefixlen:
                continue

            cmds.append(f"ip route replace {_normalize(dst)} dev {eth} scope link")

        for r in routes.get("ipv6", []):
            if r.get("proto") != "connected":
                continue

            dst = r.get("dst")
            if not dst:
                continue

            net = ipaddress.ip_network(dst, strict=False)
            if net.prefixlen == net.max_prefixlen:
                continue

            cmds.append(f"ip -6 route replace {_normalize(dst)} dev {eth}")

    return cmds
