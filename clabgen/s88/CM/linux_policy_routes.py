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


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    # Phase 1: collect lane data for all lanes that have policy routes.
    # Each entry: (slot, table_id, priority, lane_eths, shared_eths, routes4, routes6)
    lanes: List[Tuple[int, int, int, List[str], List[str], Dict, Dict]] = []

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

        lane_eths = [eth]
        shared_eths = [s for s in source_eths if s != eth]
        lanes.append((slot, table_id, priority, lane_eths, shared_eths, routes4, routes6))

    # Phase 2: render policy tables and generic iif rules (order-independent).
    for _slot, table_id, priority, lane_eths, _shared_eths, routes4, routes6 in lanes:
        if routes4 != {}:
            _render_policy_table(cmds, "ip", table_id, routes4)
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )
        if routes6 != {}:
            _render_policy_table(cmds, "ip -6", table_id, routes6)
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip -6 rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )

    # Phase 3: shared-interface destination-based rules.
    # Process lanes in DESCENDING priority order so higher-priority-number
    # lanes claim destinations first. Lower-priority-number lanes skip
    # destinations already claimed by a higher-priority-number lane.
    claimed4: Set[Tuple[str, str]] = set()  # (dst, src_eth)
    claimed6: Set[Tuple[str, str]] = set()

    # Sort by priority descending (highest number first)
    sorted_lanes = sorted(lanes, key=lambda x: x[2], reverse=True)

    for _slot, table_id, priority, _lane_eths, shared_eths, routes4, routes6 in sorted_lanes:
        if routes4 != {} and shared_eths:
            for dst in sorted(routes4.keys()):
                if dst == "0.0.0.0/0":
                    continue
                for src_eth in shared_eths:
                    if (dst, src_eth) in claimed4:
                        continue
                    claimed4.add((dst, src_eth))
                    cmds.append(
                        f"sh -c 'ip rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )
        if routes6 != {} and shared_eths:
            for dst in sorted(routes6.keys()):
                if dst == "::/0":
                    continue
                for src_eth in shared_eths:
                    if (dst, src_eth) in claimed6:
                        continue
                    claimed6.add((dst, src_eth))
                    cmds.append(
                        f"sh -c 'ip -6 rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )

    # Phase 4: policy-node return-path routing.
    # For nodes where each lane has a dedicated uplink-facing and
    # downstream-facing interface pair (policy node, downstream-selector),
    # generate destination-based ip rules on the uplink-facing interface
    # that direct return traffic to the correct downstream-facing table.
    #
    # Build mappings: access -> [(ds_table, ds_priority, ds_routes4, ds_routes6), ...]
    #                 access -> [(us_table, us_priority, us_eths), ...]
    ds_by_access: Dict[str, List[Tuple[int, int, Dict, Dict]]] = {}
    us_by_access: Dict[str, List[Tuple[int, int, List[str]]]] = {}

    for _slot, table_id, priority, lane_eths, _shared_eths, routes4, routes6 in sorted_lanes:
        if routes4 == {} and routes6 == {}:
            continue
        for src_eth in lane_eths:
            # Find the original lane data for this interface
            for ifname, eth in eth_map.items():
                if eth == src_eth:
                    iface = node.get("interfaces", {}).get(ifname, {})
                    lane = _lane(iface)
                    access = _lane_access(lane)
                    kind = lane.get("kind")
                    if access is None:
                        continue
                    if kind == "access-uplink":
                        us_by_access.setdefault(access, []).append(
                            (table_id, priority, lane_eths)
                        )
                    elif kind in ("access", "access-edge"):
                        ds_by_access.setdefault(access, []).append(
                            (table_id, priority, routes4, routes6)
                        )
                    break
            else:
                continue

    # Generate cross-rules: for each access, link US-facing interfaces to
    # DS-facing tables via destination-based ip rules.
    for access in sorted(set(ds_by_access.keys()) & set(us_by_access.keys())):
        for us_table, us_priority, us_eths in us_by_access[access]:
            for ds_table, ds_priority, routes4, routes6 in ds_by_access[access]:
                if routes4:
                    for dst in sorted(routes4.keys()):
                        if dst == "0.0.0.0/0":
                            continue
                        for src_eth in us_eths:
                            if (dst, src_eth) in claimed4:
                                continue
                            claimed4.add((dst, src_eth))
                            cmds.append(
                                f"sh -c 'ip rule add to {dst} iif {src_eth} priority {us_priority} table {ds_table} 2>/dev/null || true'"
                            )
                if routes6:
                    for dst in sorted(routes6.keys()):
                        if dst == "::/0":
                            continue
                        for src_eth in us_eths:
                            if (dst, src_eth) in claimed6:
                                continue
                            claimed6.add((dst, src_eth))
                            cmds.append(
                                f"sh -c 'ip -6 rule add to {dst} iif {src_eth} priority {us_priority} table {ds_table} 2>/dev/null || true'"
                            )

    return cmds
