from __future__ import annotations

from typing import Any, Dict, List, Tuple

from clabgen.s88.CM.linux_route_state import _connected_prefixes, _local_ips
from clabgen.s88.CM.linux_route_via import (
    _effective_via4,
    _effective_via6,
    _route_via_is_local,
)
from clabgen.s88.CM.linux_route_values import (
    _dst,
    _host_prefix,
    _normalize_prefix,
    _route_lists,
)


def _render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    routes4: Dict[str, List[Tuple[str, int]]] = {}
    routes6: Dict[str, List[Tuple[str, int]]] = {}
    connected4, connected6 = _connected_prefixes(node)
    local4, local6 = _local_ips(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for route in routes["ipv4"]:
            dst = _dst(route)
            via = _effective_via4(node, iface, route)

            if not dst or not via or dst == "0.0.0.0/0":
                continue

            dst = _normalize_prefix(dst)
            if route.get("proto") == "connected":
                continue
            if dst in connected4:
                continue
            if _route_via_is_local(route, 4, local4, local6):
                continue

            if iface.get("kind") == "overlay":
                via_host = _host_prefix(via, 4)
                if via_host:
                    via_cmd = f"ip route replace {via_host} dev eth{eth}"
                    if via_cmd not in seen:
                        seen.add(via_cmd)
                        cmds.append(via_cmd)

            _add_route(routes4, dst, via, eth)

        for route in routes["ipv6"]:
            dst = _dst(route)
            via = _effective_via6(node, iface, route)

            if not dst or not via or dst == "::/0":
                continue

            dst = _normalize_prefix(dst)
            if route.get("proto") == "connected":
                continue
            if dst in connected6:
                continue
            if _route_via_is_local(route, 6, local4, local6):
                continue

            if iface.get("kind") == "overlay":
                via_host = _host_prefix(via, 6)
                if via_host:
                    via_cmd = f"ip -6 route replace {via_host} dev eth{eth}"
                    if via_cmd not in seen:
                        seen.add(via_cmd)
                        cmds.append(via_cmd)

            _add_route(routes6, dst, via, eth)

    _append_route_groups(cmds, seen, "ip", routes4)
    _append_route_groups(cmds, seen, "ip -6", routes6)
    return cmds


def _render_default_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    defaults4: Dict[str, List[Tuple[str, int]]] = {}
    defaults6: Dict[str, List[Tuple[str, int]]] = {}
    local4, local6 = _local_ips(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for route in routes["ipv4"]:
            if _dst(route) != "0.0.0.0/0":
                continue
            if _route_via_is_local(route, 4, local4, local6):
                continue

            via = _effective_via4(node, iface, route)
            if via:
                _add_route(defaults4, "default", via, eth)

        for route in routes["ipv6"]:
            if _dst(route) != "::/0":
                continue
            if _route_via_is_local(route, 6, local4, local6):
                continue

            via = _effective_via6(node, iface, route)
            if via:
                _add_route(defaults6, "default", via, eth)

    _append_route_groups(cmds, seen, "ip", defaults4)
    _append_route_groups(cmds, seen, "ip -6", defaults6)
    return cmds


def _add_route(
    groups: Dict[str, List[Tuple[str, int]]],
    dst: str,
    via: str,
    eth: int,
) -> None:
    nexthops = groups.setdefault(dst, [])
    hop = (via, eth)
    if hop not in nexthops:
        nexthops.append(hop)


def _append_route_groups(
    cmds: List[str],
    seen: set[str],
    ip_cmd: str,
    groups: Dict[str, List[Tuple[str, int]]],
) -> None:
    for dst in sorted(groups.keys()):
        nexthops = groups[dst]
        if len(nexthops) == 1:
            via, eth = nexthops[0]
            cmd = f"{ip_cmd} route replace {dst} via {via} dev eth{eth} onlink"
        else:
            parts = [f"{ip_cmd} route replace {dst}"]
            for via, eth in sorted(nexthops, key=lambda item: (item[1], item[0])):
                parts.append(f"nexthop via {via} dev eth{eth} onlink")
            cmd = " ".join(parts)
        if cmd not in seen:
            seen.add(cmd)
            cmds.append(cmd)


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
