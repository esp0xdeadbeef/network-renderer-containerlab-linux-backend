from __future__ import annotations

import ipaddress
from typing import Any, Dict, List, Set, Tuple

from clabgen.s88.CM.linux_addressing import _peer_in_subnet
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


def _add_connected_subnet_route(
    cmds: List[str],
    *,
    ip_cmd: str,
    table_id: int,
    iface: Dict[str, Any],
    eth: str,
    field: str,
) -> None:
    """Add a route for the directly-connected subnet of *iface* to *table_id*.

    Policy-only routes in the CPM describe via-remote destinations. The
    connected subnet of the downstream interface itself is not a policyOnly
    route — it is a kernel scope-link route. Without an explicit table route,
    return traffic for a peer on that link falls through to the default route,
    which may loop back to the upstream node (SMS-101).
    """
    cidr = iface.get(field)
    if not isinstance(cidr, str) or not cidr:
        return
    try:
        subnet = str(ipaddress.ip_interface(cidr).network)
    except Exception:
        return
    if _is_default(subnet):
        return
    peer = _peer_in_subnet(cidr)
    if not peer:
        return
    cmds.append(
        f"sh -c '{ip_cmd} route replace table {table_id} {subnet}"
        f" via {peer} dev {eth} onlink 2>/dev/null || true'"
    )


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
        # Do NOT skip lanes with empty routes — deny-by-default lanes
        # must still get an ip rule so the kernel can route (to blackhole)
        # instead of generating ICMP "Network Unreachable" before nftables
        # policy drop can act.  (FS-170 silent-drop / D9)

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
    # Skip generic iif rules for access-uplink interfaces — their return-path
    # routing is handled by Phase 4 cross-rules (SMS-101).
    for _slot, table_id, priority, lane_eths, _shared_eths, routes4, routes6 in lanes:
        # Find whether this lane is an access-uplink (US-facing) interface
        is_uplink = False
        for src_eth in lane_eths:
            for ifname, eth in eth_map.items():
                if eth == src_eth:
                    iface = node.get("interfaces", {}).get(ifname, {})
                    lane = _lane(iface)
                    if lane.get("kind") == "access-uplink":
                        is_uplink = True
                    break
            if is_uplink:
                break

        if routes4 != {}:
            _render_policy_table(cmds, "ip", table_id, routes4)
            if not is_uplink:
                for source_eth in lane_eths:
                    cmds.append(
                        f"sh -c 'ip rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )
        elif not is_uplink:
            # Deny-by-default lane: add blackhole default so the kernel
            # can route silently instead of generating ICMP (FS-170/D9).
            cmds.append(
                f"sh -c 'ip route replace table {table_id} blackhole 0.0.0.0/0 2>/dev/null || true'"
            )
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )
        if routes6 != {}:
            _render_policy_table(cmds, "ip -6", table_id, routes6)
            if not is_uplink:
                for source_eth in lane_eths:
                    cmds.append(
                        f"sh -c 'ip -6 rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )
        elif routes4 == {} and not is_uplink:
            # Deny-by-default lane: add IPv6 ip rule too.
            for source_eth in lane_eths:
                cmds.append(
                    f"sh -c 'ip -6 rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )

    # Phase 3: shared-interface destination-based rules.
    # Build connected subnet sets per lane (from the lane's own interface
    # addr4/addr6).  Only claim destinations that are within one of the
    # lane's own connected subnets on the shared interface.  This prevents
    # lanes from claiming destinations that belong to other lanes (CPM's
    # policyTableComplements adds cross-lane routes — the renderer must
    # filter them per SMS-100).
    lane_subnets4: Dict[int, Set[ipaddress.IPv4Network]] = {}
    lane_subnets6: Dict[int, Set[ipaddress.IPv6Network]] = {}
    for _slot, table_id, _priority, lane_eths, _shared_eths, _routes4, _routes6 in lanes:
        sub4: Set[ipaddress.IPv4Network] = set()
        sub6: Set[ipaddress.IPv6Network] = set()
        for src_eth in lane_eths:
            for ifname, eth in eth_map.items():
                if eth == src_eth:
                    iface = node.get("interfaces", {}).get(ifname, {})
                    for field, sset in (("addr4", sub4), ("addr6", sub6)):
                        cidr = iface.get(field)
                        if isinstance(cidr, str) and cidr:
                            try:
                                net = ipaddress.ip_interface(cidr).network
                                sset.add(net)
                            except Exception:
                                pass
                    break
        lane_subnets4[table_id] = sub4
        lane_subnets6[table_id] = sub6

    claimed4: Set[Tuple[str, str]] = set()  # (dst, src_eth)
    claimed6: Set[Tuple[str, str]] = set()

    sorted_lanes_asc = sorted(lanes, key=lambda x: x[2])

    for _slot, table_id, priority, _lane_eths, shared_eths, routes4, routes6 in sorted_lanes_asc:
        sub4 = lane_subnets4.get(table_id, set())
        sub6 = lane_subnets6.get(table_id, set())
        if routes4 != {} and shared_eths:
            for dst in sorted(routes4.keys()):
                if dst == "0.0.0.0/0":
                    continue
                # Only claim if destination is within one of this lane's
                # connected subnets (SMS-100).
                dst_in_subnet = False
                try:
                    dst_net = ipaddress.ip_network(dst, strict=False)
                    dst_in_subnet = any(
                        dst_net.subnet_of(s) or dst_net == s for s in sub4
                    )
                except Exception:
                    pass
                if not dst_in_subnet:
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
                dst_in_subnet = False
                try:
                    dst_net = ipaddress.ip_network(dst, strict=False)
                    dst_in_subnet = any(
                        dst_net.subnet_of(s) or dst_net == s for s in sub6
                    )
                except Exception:
                    pass
                if not dst_in_subnet:
                    continue
                for src_eth in shared_eths:
                    if (dst, src_eth) in claimed6:
                        continue
                    claimed6.add((dst, src_eth))
                    cmds.append(
                        f"sh -c 'ip -6 rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )

    # Phase 4: policy-node and DS return-path routing.
    # For nodes where each lane has a dedicated uplink-facing and
    # downstream-facing interface pair (policy node, downstream-selector),
    # generate destination-based ip rules on the uplink-facing interface
    # that direct return traffic to the correct downstream-facing table.
    #
    # Pattern: access-uplink interfaces (toward US) need routes for
    # subnets behind access/access-edge interfaces (toward DS/access).
    # Pattern: access interfaces (toward policy) need routes for
    # subnets behind access-edge interfaces (toward access nodes).
    #
    # Build mappings:
    #   downstream_by_access: access -> [(table, priority, routes4, routes6)]
    #     (interfaces that face downstream — access or access-edge)
    #   upstream_by_access: access -> [(table, priority, eths)]
    #     (interfaces that face upstream — access-uplink or access)
    downstream_by_access: Dict[str, List[Tuple[int, int, Dict, Dict, Dict[str, Any], str]]] = {}
    upstream_by_access: Dict[str, List[Tuple[int, int, List[str]]]] = {}

    # Use descending sort for Phase 4/5 (original behavior)
    sorted_lanes_desc = sorted(lanes, key=lambda x: x[2], reverse=True)

    for _slot, table_id, priority, lane_eths, _shared_eths, routes4, routes6 in sorted_lanes_desc:
        if routes4 == {} and routes6 == {}:
            continue
        for src_eth in lane_eths:
            for ifname, eth in eth_map.items():
                if eth == src_eth:
                    iface = node.get("interfaces", {}).get(ifname, {})
                    lane = _lane(iface)
                    access = _lane_access(lane)
                    kind = lane.get("kind")
                    if access is None:
                        continue
                    if kind in ("access-uplink", "access"):
                        upstream_by_access.setdefault(access, []).append(
                            (table_id, priority, lane_eths)
                        )
                    if kind in ("access", "access-edge"):
                        downstream_by_access.setdefault(access, []).append(
                            (table_id, priority, routes4, routes6, iface, eth)
                        )
                    break
            else:
                continue

    # Generate cross-rules: for each access, link upstream interfaces to
    # downstream tables via destination-based ip rules.
    for access in sorted(set(upstream_by_access.keys()) & set(downstream_by_access.keys())):
        for us_table, us_priority, us_eths in upstream_by_access[access]:
            for ds_table, ds_priority, routes4, routes6, _ds_iface, _ds_eth in downstream_by_access[access]:
                # Skip self-references (same table)
                if us_table == ds_table:
                    continue
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

    # Phase 5: return-path policy table route augmentation.
    # For access/access-edge interfaces, add routes for subnets reachable
    # via downstream interfaces that share the same access.
    # This ensures the upstream-facing table has direct routes to
    # downstream subnets instead of falling back to the default route
    # (which may point back to the upstream node causing a loop).
    for access in sorted(set(upstream_by_access.keys()) & set(downstream_by_access.keys())):
        for us_table, us_priority, us_eths in upstream_by_access[access]:
            for ds_table, ds_priority, routes4, routes6, ds_iface, ds_eth in downstream_by_access[access]:
                if us_table == ds_table:
                    continue
                if routes4:
                    for dst in sorted(routes4.keys()):
                        if dst == "0.0.0.0/0":
                            continue
                        for via, eth in routes4[dst]:
                            cmds.append(
                                f"sh -c 'ip route replace table {us_table} {dst} via {via} dev {eth} onlink 2>/dev/null || true'"
                            )
                if routes6:
                    for dst in sorted(routes6.keys()):
                        if dst == "::/0":
                            continue
                        for via, eth in routes6[dst]:
                            cmds.append(
                                f"sh -c 'ip -6 route replace table {us_table} {dst} via {via} dev {eth} onlink 2>/dev/null || true'"
                            )
                # Add connected-subnet route for the downstream interface.
                # The upstream-facing table needs to reach subnets that are
                # directly connected on the downstream interface, not just
                # policyOnly routes (which are via-remote). Without this,
                # return traffic destined for a peer on the downstream link
                # hits the upstream table's default route, which may loop
                # back to the upstream node (SMS-101).
                _add_connected_subnet_route(cmds, ip_cmd="ip", table_id=us_table,
                    iface=ds_iface, eth=ds_eth, field="addr4")
                _add_connected_subnet_route(cmds, ip_cmd="ip -6", table_id=us_table,
                    iface=ds_iface, eth=ds_eth, field="addr6")

    return cmds
