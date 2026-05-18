from __future__ import annotations

from typing import Any, Dict, List, Tuple

from clabgen.s88.CM.linux_route_values import _dst, _normalize_prefix, _route_lists
from clabgen.s88.CM.linux_route_via import _effective_via4, _effective_via6


def _lane(iface_or_route: Dict[str, Any]) -> Dict[str, Any]:
    value = iface_or_route.get("lane")
    return value if isinstance(value, dict) else {}


def _lane_access(value: Dict[str, Any]) -> str | None:
    access = value.get("access")
    return access if isinstance(access, str) and access else None


def _lane_uplink(value: Dict[str, Any]) -> str | None:
    uplink = value.get("uplink")
    return uplink if isinstance(uplink, str) and uplink else None


def _route_matches_ingress(
    ingress_lane: Dict[str, Any], route_lane: Dict[str, Any]
) -> bool:
    ingress_access = _lane_access(ingress_lane)
    route_access = _lane_access(route_lane)
    if ingress_access is None or route_access != ingress_access:
        return False

    ingress_uplink = _lane_uplink(ingress_lane)
    route_uplink = _lane_uplink(route_lane)
    return (
        ingress_uplink is None or route_uplink is None or ingress_uplink == route_uplink
    )


def _append_policy_route(
    groups: Dict[str, List[Tuple[str, int]]],
    dst: str | None,
    via: str | None,
    eth: int,
) -> None:
    if not dst or not via:
        return
    hop = (via, eth)
    entries = groups.setdefault(_normalize_prefix(dst), [])
    if hop not in entries:
        entries.append(hop)


def _policy_groups_for_ingress(
    node: Dict[str, Any],
    eth_map: Dict[str, int],
    ingress_ifname: str,
    ingress_iface: Dict[str, Any],
) -> tuple[Dict[str, List[Tuple[str, int]]], Dict[str, List[Tuple[str, int]]]]:
    ingress_lane = _lane(ingress_iface)
    routes4: Dict[str, List[Tuple[str, int]]] = {}
    routes6: Dict[str, List[Tuple[str, int]]] = {}

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        if ifname == ingress_ifname:
            continue
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)
        for route in routes["ipv4"]:
            if route.get("policyOnly") is not True:
                continue
            if not _route_matches_ingress(ingress_lane, _lane(route)):
                continue
            _append_policy_route(
                routes4, _dst(route), _effective_via4(node, iface, route), eth
            )

        for route in routes["ipv6"]:
            if route.get("policyOnly") is not True:
                continue
            if not _route_matches_ingress(ingress_lane, _lane(route)):
                continue
            _append_policy_route(
                routes6, _dst(route), _effective_via6(node, iface, route), eth
            )

    return routes4, routes6


def _render_group(
    ip_cmd: str, table_id: int, dst: str, hops: List[Tuple[str, int]]
) -> str:
    if len(hops) == 1:
        via, eth = hops[0]
        return f"{ip_cmd} route replace table {table_id} {dst} via {via} dev eth{eth} onlink"

    parts = [f"{ip_cmd} route replace table {table_id} {dst}"]
    for via, eth in sorted(hops, key=_hop_sort_key):
        parts.append(f"nexthop via {via} dev eth{eth} onlink")
    return " ".join(parts)


def _hop_sort_key(hop: Tuple[str, int]) -> Tuple[int, str]:
    via, eth = hop
    return eth, via


def _render_policy_table(
    cmds: List[str],
    ip_cmd: str,
    table_id: int,
    groups: Dict[str, List[Tuple[str, int]]],
) -> None:
    for dst in sorted(groups.keys()):
        cmds.append(_render_group(ip_cmd, table_id, dst, groups[dst]))


def render(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None or _lane_access(_lane(iface)) is None:
            continue

        routes4, routes6 = _policy_groups_for_ingress(node, eth_map, ifname, iface)
        if routes4 == {} and routes6 == {}:
            continue

        table_id = 1000 + eth
        priority = 10000 + eth
        if routes4 != {}:
            _render_policy_table(cmds, "ip", table_id, routes4)
            cmds.append(
                f"ip rule add iif eth{eth} priority {priority} table {table_id} 2>/dev/null || true"
            )
        if routes6 != {}:
            _render_policy_table(cmds, "ip -6", table_id, routes6)
            cmds.append(
                f"ip -6 rule add iif eth{eth} priority {priority} table {table_id} 2>/dev/null || true"
            )

    return cmds
