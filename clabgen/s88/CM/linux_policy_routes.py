from __future__ import annotations

from typing import Any, Dict, List, Set, Tuple

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


def _is_default(dst: str | None) -> bool:
    return dst in {"0.0.0.0/0", "::/0"}


def _route_matches_ingress(
    ingress_lane: Dict[str, Any], route_lane: Dict[str, Any]
) -> bool:
    ingress_access = _lane_access(ingress_lane)
    route_access = _lane_access(route_lane)
    if ingress_access is None or route_access != ingress_access:
        return False

    ingress_uplink = _lane_uplink(ingress_lane)
    route_uplink = _lane_uplink(route_lane)
    return None in {ingress_uplink, route_uplink} or ingress_uplink == route_uplink


def _same_uplink(left: Dict[str, Any], right: Dict[str, Any]) -> bool:
    left_uplink = _lane_uplink(left)
    right_uplink = _lane_uplink(right)
    return left_uplink is not None and left_uplink == right_uplink


def _source_interfaces_for_lane(
    node: Dict[str, Any],
    target_ifname: str,
    target_iface: Dict[str, Any],
) -> List[str]:
    target_lane = _lane(target_iface)
    sources: List[str] = [target_ifname]

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        if ifname == target_ifname:
            continue
        iface = node["interfaces"][ifname]
        lane = _lane(iface)
        if _lane_access(lane) is None and _same_uplink(lane, target_lane):
            sources.append(ifname)

    return sources


def _append_policy_route(
    groups: Dict[str, List[Tuple[str, str]]],
    dst: str | None,
    via: str | None,
    eth: str,
) -> None:
    if not dst or not via:
        return
    hop = (via, eth)
    entries = groups.setdefault(_normalize_prefix(dst), [])
    if hop not in entries:
        entries.append(hop)


def _policy_groups_for_lane(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
    target_ifname: str,
    target_iface: Dict[str, Any],
) -> tuple[Dict[str, List[Tuple[str, str]]], Dict[str, List[Tuple[str, str]]]]:
    target_lane = _lane(target_iface)
    routes4: Dict[str, List[Tuple[str, str]]] = {}
    routes6: Dict[str, List[Tuple[str, str]]] = {}
    preferred4: set[str] = set()
    preferred6: set[str] = set()

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)
        for route in routes["ipv4"]:
            if route.get("policyOnly") is not True:
                continue
            route_lane = _lane(route) or (_lane(iface) if _is_default(_dst(route)) else {})  # fmt: skip
            if not _route_matches_ingress(target_lane, route_lane):
                continue
            dst = _dst(route)
            if ifname != target_ifname and dst in preferred4:
                continue
            if ifname == target_ifname and not _is_default(dst):
                preferred4.add(_normalize_prefix(dst))
                routes4.pop(_normalize_prefix(dst), None)
            _append_policy_route(routes4, dst, _effective_via4(node, iface, route), eth)

        for route in routes["ipv6"]:
            if route.get("policyOnly") is not True:
                continue
            route_lane = _lane(route) or (_lane(iface) if _is_default(_dst(route)) else {})  # fmt: skip
            if not _route_matches_ingress(target_lane, route_lane):
                continue
            dst = _dst(route)
            if ifname != target_ifname and dst in preferred6:
                continue
            if ifname == target_ifname and not _is_default(dst):
                preferred6.add(_normalize_prefix(dst))
                routes6.pop(_normalize_prefix(dst), None)
            _append_policy_route(routes6, dst, _effective_via6(node, iface, route), eth)

    return routes4, routes6


def _render_group(
    ip_cmd: str, table_id: int, dst: str, hops: List[Tuple[str, str]]
) -> str:
    if len(hops) == 1:
        via, eth = hops[0]
        return (
            f"{ip_cmd} route replace table {table_id} {dst} via {via} dev {eth} onlink"
        )

    parts = [f"{ip_cmd} route replace table {table_id} {dst}"]
    for via, eth in sorted(hops, key=_hop_sort_key):
        parts.append(f"nexthop via {via} dev {eth} onlink")
    return " ".join(parts)


def _hop_sort_key(hop: Tuple[str, str]) -> Tuple[str, str]:
    via, eth = hop
    return eth, via


def _table_slot(eth_map: Dict[str, str], target_ifname: str) -> int:
    names = sorted(set(eth_map.values()))
    return names.index(target_ifname) + 1


def _render_policy_table(
    cmds: List[str],
    ip_cmd: str,
    table_id: int,
    groups: Dict[str, List[Tuple[str, str]]],
) -> None:
    for dst in sorted(groups.keys()):
        cmds.append(_render_group(ip_cmd, table_id, dst, groups[dst]))


def _shared_source_rules(
    table_id: int,
    priority: int,
    routes4: Dict[str, List[Tuple[str, str]]],
    routes6: Dict[str, List[Tuple[str, str]]],
    source_eths: List[str],
    lane_eth: str,
) -> List[str]:
    cmds: List[str] = []
    shared = [s for s in source_eths if s != lane_eth]
    if not shared:
        return cmds
    # For shared source interfaces (e.g. core-facing iface used by multiple lanes),
    # emit destination-based ip rules so each subnet routes through its correct lane.
    # Without this, first-matching iif rule captures all return traffic (guest wins).
    for dst in sorted(routes4.keys()):
        for src_eth in shared:
            cmds.append(
                f"sh -c 'ip rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
            )
    for dst in sorted(routes6.keys()):
        for src_eth in shared:
            cmds.append(
                f"sh -c 'ip -6 rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
            )
    return cmds


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None or _lane_access(_lane(iface)) is None:
            continue

        routes4, routes6 = _policy_groups_for_lane(node, eth_map, ifname, iface)
        if routes4 == {} and routes6 == {}:
            continue

        slot = _table_slot(eth_map, eth)
        table_id = 1000 + slot
        priority = 10000 + slot
        source_eths: List[str] = []
        for source in _source_interfaces_for_lane(node, ifname, iface):
            source_eth = eth_map.get(source)
            if source_eth is not None:
                source_eths.append(source_eth)
        # Determine which source interfaces are this lane's own vs shared.
        lane_eths = [eth]
        shared_eths = [s for s in source_eths if s != eth]
        if routes4 != {}:
            _render_policy_table(cmds, "ip", table_id, routes4)
            # Add generic iif rule for this lane's own interface
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )
            # For shared interfaces, use destination-based rules so each
            # subnet routes through its correct lane instead of all traffic
            # going to the first-matching generic iif rule.
            for dst in sorted(routes4.keys()):
                for src_eth in shared_eths:
                    cmds.append(
                        f"sh -c 'ip rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )
        if routes6 != {}:
            _render_policy_table(cmds, "ip -6", table_id, routes6)
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip -6 rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )
            for dst in sorted(routes6.keys()):
                for src_eth in shared_eths:
                    cmds.append(
                        f"sh -c 'ip -6 rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )

    return cmds
