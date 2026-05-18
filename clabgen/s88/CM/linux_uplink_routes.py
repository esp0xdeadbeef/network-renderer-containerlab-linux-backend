from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.linux_route_values import _dst, _normalize_prefix, _route_lists
from clabgen.s88.CM.linux_route_via import _effective_via4, _effective_via6


def _render_uplink_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for route in routes["ipv4"]:
            if route.get("proto") != "uplink":
                continue
            via = _effective_via4(node, iface, route)
            dst = _dst(route)
            if not via or not dst:
                continue

            if dst == "0.0.0.0/0":
                cmd = f"ip route replace default via {via} dev eth{eth} onlink"
            else:
                cmd = f"ip route replace {_normalize_prefix(dst)} via {via} dev eth{eth} onlink"

            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

        for route in routes["ipv6"]:
            if route.get("proto") != "uplink":
                continue
            via = _effective_via6(node, iface, route)
            dst = _dst(route)
            if not via or not dst:
                continue

            if dst == "::/0":
                cmd = f"ip -6 route replace default via {via} dev eth{eth} onlink"
            else:
                cmd = f"ip -6 route replace {_normalize_prefix(dst)} via {via} dev eth{eth} onlink"

            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds
