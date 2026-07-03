from __future__ import annotations

import ipaddress
from typing import Any, Dict, List, Set, Tuple

from clabgen.s88.CM.linux_addressing import _peer_in_subnet
from clabgen.s88.CM.linux_route_values import (
    _dst,
    _normalize_prefix,
    _route_lists,
    _via4,
    _via6,
)
from clabgen.s88.CM.linux_route_via import _effective_via4, _effective_via6, _same_subnet


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _lane(iface_or_route: Dict[str, Any]) -> Dict[str, Any]:
    value = iface_or_route.get("lane")
    backing = iface_or_route.get("backingRef")
    if not isinstance(value, dict) or not value:
        if isinstance(backing, dict):
            value = backing.get("lane")
    lane = value if isinstance(value, dict) else {}
    direct_uplinks = iface_or_route.get("uplinks")
    if isinstance(direct_uplinks, list) and direct_uplinks:
        merged = dict(lane)
        merged["uplinks"] = _dedupe_strings(
            list(merged.get("uplinks") or []) + direct_uplinks
        )
        lane = merged
    if isinstance(backing, dict):
        backing_uplinks = backing.get("uplinks")
        if isinstance(backing_uplinks, list) and backing_uplinks:
            merged = dict(lane)
            merged["uplinks"] = _dedupe_strings(
                list(merged.get("uplinks") or []) + backing_uplinks
            )
            return merged
    return lane


def _dedupe_strings(values: List[Any]) -> List[str]:
    seen: Set[str] = set()
    result: List[str] = []
    for value in values:
        if isinstance(value, str) and value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def _lane_access(value: Dict[str, Any]) -> str | None:
    access = value.get("access")
    return access if isinstance(access, str) and access else None


def _lane_uplink(value: Dict[str, Any]) -> str | None:
    uplink = value.get("uplink")
    return uplink if isinstance(uplink, str) and uplink else None


def _lane_uplinks(value: Dict[str, Any]) -> Set[str]:
    uplinks: Set[str] = set()
    singular = _lane_uplink(value)
    if singular is not None:
        uplinks.add(singular)
    listed = value.get("uplinks")
    if isinstance(listed, list):
        for uplink in listed:
            if isinstance(uplink, str) and uplink:
                uplinks.add(uplink)
    return uplinks


def _is_default(dst: str | None) -> bool:
    return dst in {"0.0.0.0/0", "::/0"}


def _route_matches_ingress(
    ingress_lane: Dict[str, Any], route_lane: Dict[str, Any], dst: str | None
) -> bool:
    ingress_access = _lane_access(ingress_lane)
    route_access = _lane_access(route_lane)
    if ingress_access is None:
        if not _lane_uplinks(ingress_lane):
            return False
        if route_access is None:
            return _is_default(dst) and _same_uplink(ingress_lane, route_lane)
        return _same_uplink(ingress_lane, route_lane)

    if route_access is None:
        return _is_default(dst) and _same_uplink(ingress_lane, route_lane)

    if route_access != ingress_access:
        return False

    ingress_uplink = _lane_uplink(ingress_lane)
    route_uplink = _lane_uplink(route_lane)
    return None in {ingress_uplink, route_uplink} or ingress_uplink == route_uplink


def _same_uplink(left: Dict[str, Any], right: Dict[str, Any]) -> bool:
    return bool(_lane_uplinks(left) & _lane_uplinks(right))


def _has_policy_only_routes(iface: Dict[str, Any]) -> bool:
    routes = _route_lists(iface)
    return any(route.get("policyOnly") is True for route in routes["ipv4"] + routes["ipv6"])


def _is_policy_routing_surface(iface: Dict[str, Any]) -> bool:
    lane = _lane(iface)
    if _lane_access(lane) is not None:
        return True
    return (
        bool(_lane_uplinks(lane))
        and _has_policy_only_routes(iface)
        and isinstance(iface.get("policyRoutingAllocation"), dict)
    )


PolicyHop = Tuple[str | None, str]


def _logical_interface_for_runtime(
    eth_map: Dict[str, str], runtime_or_logical: Any
) -> str | None:
    if not isinstance(runtime_or_logical, str) or not runtime_or_logical:
        return None
    if runtime_or_logical in eth_map:
        return runtime_or_logical
    for ifname, runtime in eth_map.items():
        if runtime == runtime_or_logical:
            return ifname
    return None


def _forwarding_sources_for_target(
    node: Dict[str, Any], eth_map: Dict[str, str], target_ifname: str
) -> List[str]:
    target_eth = eth_map.get(target_ifname)
    if target_eth is None:
        return []

    result: List[str] = []
    forwarding_intent = node.get("forwardingIntent")
    rules = _dict(forwarding_intent).get("rules", [])
    if not isinstance(rules, list):
        return result

    for rule in rules:
        if not isinstance(rule, dict) or rule.get("action") != "accept":
            continue
        to_iface = rule.get("toInterface")
        if to_iface not in {target_ifname, target_eth}:
            continue
        source_ifname = _logical_interface_for_runtime(eth_map, rule.get("fromInterface"))
        if source_ifname is not None and source_ifname != target_ifname:
            result.append(source_ifname)
    return _dedupe_strings(result)


def _source_interfaces_for_lane(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
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

    sources.extend(_forwarding_sources_for_target(node, eth_map, target_ifname))
    return _dedupe_strings(sources)


def _route_surface_for_lane(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
    fallback_ifname: str,
    route_lane: Dict[str, Any],
    route: Dict[str, Any],
    family: int,
) -> Tuple[Dict[str, Any], str] | None:
    via = _via4(route) if family == 4 else _via6(route)
    addr_field = "addr4" if family == 4 else "addr6"
    if isinstance(via, str) and via:
        for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
            iface = node["interfaces"][ifname]
            eth = eth_map.get(ifname)
            if eth is not None and _same_subnet(via, iface.get(addr_field)):
                return iface, eth

    route_access = _lane_access(route_lane)
    route_uplink = _lane_uplink(route_lane)
    if route_access is not None and route_uplink is not None:
        for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
            iface = node["interfaces"][ifname]
            iface_lane = _lane(iface)
            if (
                _lane_access(iface_lane) == route_access
                and _lane_uplink(iface_lane) == route_uplink
            ):
                eth = eth_map.get(ifname)
                return (iface, eth) if eth is not None else None
    fallback_iface = (node.get("interfaces", {}) or {}).get(fallback_ifname)
    fallback_eth = eth_map.get(fallback_ifname)
    if isinstance(fallback_iface, dict) and fallback_eth is not None:
        return fallback_iface, fallback_eth
    return None


def _append_policy_route(
    groups: Dict[str, List[PolicyHop]],
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


def _append_connected_policy_route(
    groups: Dict[str, List[PolicyHop]],
    dst: str | None,
    eth: str,
) -> None:
    if not dst:
        return
    hop = (None, eth)
    entries = groups.setdefault(_normalize_prefix(dst), [])
    if hop not in entries:
        entries.append(hop)


def _policy_groups_for_lane(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
    target_ifname: str,
    target_iface: Dict[str, Any],
) -> tuple[Dict[str, List[PolicyHop]], Dict[str, List[PolicyHop]]]:
    target_lane = _lane(target_iface)
    routes4: Dict[str, List[Tuple[str, str]]] = {}
    routes6: Dict[str, List[Tuple[str, str]]] = {}
    preferred4: set[str] = set()
    preferred6: set[str] = set()

    # Collect addr4/addr6 of OTHER interfaces with different lane.access
    target_access = _lane_access(target_lane)
    other_addrs4: set[str] = set()
    other_addrs6: set[str] = set()
    for oname, oiface in (node.get("interfaces", {}) or {}).items():
        if oname == target_ifname:
            continue
        olane = _lane(oiface)
        oaccess = _lane_access(olane)
        if target_access is not None and oaccess is not None and oaccess != target_access:
            a4 = oiface.get("addr4")
            a6 = oiface.get("addr6")
            if isinstance(a4, str):
                other_addrs4.add(a4)
            if isinstance(a6, str):
                other_addrs6.add(a6)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)
        for route in routes["ipv4"]:
            route_lane = _lane(route) or _lane(iface)
            dst = _dst(route)
            if route.get("policyOnly") is not True and ifname != target_ifname:
                continue
            if route.get("policyOnly") is True and not _route_matches_ingress(target_lane, route_lane, dst):
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and route.get("proto") == "connected":
                _append_connected_policy_route(routes4, dst, eth)
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and not dst:
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and _is_default(dst):
                route_surface = (iface, eth)
            else:
                # Skip routes whose dst is the addr4/addr6 of another lane's interface
                if dst and (dst in other_addrs4 or dst in other_addrs6):
                    continue
                route_surface = _route_surface_for_lane(node, eth_map, ifname, route_lane, route, 4)
            if route_surface is None:
                continue
            route_iface, route_eth = route_surface
            if ifname != target_ifname and dst in preferred4:
                continue
            normalized_dst = _normalize_prefix(dst)
            if ifname == target_ifname and not _is_default(dst) and normalized_dst not in preferred4:
                preferred4.add(normalized_dst)
                routes4.pop(normalized_dst, None)
            _append_policy_route(routes4, dst, _effective_via4(node, route_iface, route), route_eth)

        for route in routes["ipv6"]:
            route_lane = _lane(route) or _lane(iface)
            dst = _dst(route)
            if route.get("policyOnly") is not True and ifname != target_ifname:
                continue
            if route.get("policyOnly") is True and not _route_matches_ingress(target_lane, route_lane, dst):
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and route.get("proto") == "connected":
                _append_connected_policy_route(routes6, dst, eth)
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and not dst:
                continue
            if route.get("policyOnly") is not True and ifname == target_ifname and _is_default(dst):
                route_surface = (iface, eth)
            else:
                # Skip routes whose dst is the addr4/addr6 of another lane's interface
                if dst and (dst in other_addrs4 or dst in other_addrs6):
                    continue
                route_surface = _route_surface_for_lane(node, eth_map, ifname, route_lane, route, 6)
            if route_surface is None:
                continue
            route_iface, route_eth = route_surface
            if ifname != target_ifname and dst in preferred6:
                continue
            normalized_dst = _normalize_prefix(dst)
            if ifname == target_ifname and not _is_default(dst) and normalized_dst not in preferred6:
                preferred6.add(normalized_dst)
                routes6.pop(normalized_dst, None)
            _append_policy_route(routes6, dst, _effective_via6(node, route_iface, route), route_eth)

    return routes4, routes6


def _render_group(
    ip_cmd: str, table_id: int, dst: str, hops: List[PolicyHop]
) -> str:
    if len(hops) == 1:
        via, eth = hops[0]
        if via is None:
            return f"{ip_cmd} route replace table {table_id} {dst} dev {eth}"
        return (
            f"{ip_cmd} route replace table {table_id} {dst} via {via} dev {eth} onlink"
        )

    parts = [f"{ip_cmd} route replace table {table_id} {dst}"]
    for via, eth in sorted(hops, key=_hop_sort_key):
        if via is None:
            parts.append(f"dev {eth}")
        else:
            parts.append(f"nexthop via {via} dev {eth} onlink")
    return " ".join(parts)


def _hop_sort_key(hop: PolicyHop) -> Tuple[str, str]:
    via, eth = hop
    via_key = via if via is not None else ""
    return eth, via_key


def _table_slot(eth_map: Dict[str, str], target_ifname: str) -> int:
    names = sorted(set(eth_map.values()))
    return names.index(target_ifname) + 1


def _int_field(value: Any, field: str, ifname: str) -> int:
    if not isinstance(value, int) or value <= 0:
        raise ValueError(
            "FS-310-HDS-010-SDS-010-SMS-130: interface "
            f"{ifname!r} policyRoutingAllocation.{field} must be a positive integer"
        )
    return value


def _policy_routing_allocation(
    iface: Dict[str, Any],
    ifname: str,
) -> Tuple[int, int, int | None]:
    allocation = iface.get("policyRoutingAllocation")
    if not isinstance(allocation, dict) or not allocation:
        raise ValueError(
            "FS-310-HDS-010-SDS-010-SMS-130: interface "
            f"{ifname!r} has policy-routing lane data but lacks CPM "
            "policyRoutingAllocation; renderer must not invent route table IDs "
            "or rule priorities"
        )

    source = allocation.get("source")
    if source not in {"control-plane-model", "provider-contract"}:
        raise ValueError(
            "FS-310-HDS-010-SDS-010-SMS-130: interface "
            f"{ifname!r} policyRoutingAllocation.source must be "
            "'control-plane-model' or 'provider-contract'"
        )

    table_id = _int_field(allocation.get("tableId"), "tableId", ifname)
    if isinstance(allocation.get("tableRulePriority"), int):
        priority = _int_field(allocation.get("tableRulePriority"), "tableRulePriority", ifname)
    else:
        priority = _int_field(allocation.get("priority"), "priority", ifname)
    main_suppress_priority = allocation.get("mainSuppressPriority")
    if main_suppress_priority is not None:
        main_suppress_priority = _int_field(main_suppress_priority, "mainSuppressPriority", ifname)
    return table_id, priority, main_suppress_priority


def _render_policy_table(
    cmds: List[str],
    ip_cmd: str,
    table_id: int,
    groups: Dict[str, List[Tuple[str, str]]],
) -> None:
    for dst in sorted(groups.keys()):
        route = _render_group(ip_cmd, table_id, dst, groups[dst])
        cmds.append(route)


def _source_prefixes_for_interface(
    iface: Dict[str, Any],
    family: int,
) -> List[str]:
    result: List[str] = []
    field = "addr4" if family == 4 else "addr6"
    addr = iface.get(field)
    if isinstance(addr, str) and addr:
        try:
            network = ipaddress.ip_interface(addr).network
        except ValueError:
            network = None
        if network is not None:
            if family == 4 and network.prefixlen < 31:
                result.append(str(network))
            if family == 6 and network.prefixlen < 127:
                result.append(str(network))

    for route in _route_lists(iface)["ipv4" if family == 4 else "ipv6"]:
        if route.get("proto") != "connected":
            continue
        dst = _dst(route)
        if isinstance(dst, str) and dst and dst not in result:
            result.append(_normalize_prefix(dst))
    return _dedupe_strings(result)


def _append_policy_rule_commands(
    cmds: List[str],
    *,
    ip_cmd: str,
    table_id: int,
    priority: int,
    main_suppress_priority: int | None,
    source_iface: Dict[str, Any],
    source_eth: str,
    family: int,
    allow_unscoped: bool,
) -> None:
    prefixes = _source_prefixes_for_interface(source_iface, family)
    if prefixes:
        for prefix in prefixes:
            cmds.append(
                f"sh -c '{ip_cmd} rule add from {prefix} iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
            )
            cmds.append(
                f"sh -c '{ip_cmd} rule add to {prefix} iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
            )
            if main_suppress_priority is not None:
                cmds.append(
                    f"sh -c '{ip_cmd} rule add from {prefix} iif {source_eth} priority {main_suppress_priority} table main suppress_prefixlength 0 2>/dev/null || true'"
                )
                cmds.append(
                    f"sh -c '{ip_cmd} rule add to {prefix} iif {source_eth} priority {main_suppress_priority} table main suppress_prefixlength 0 2>/dev/null || true'"
                )
        return

    if allow_unscoped:
        cmds.append(
            f"sh -c '{ip_cmd} rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
        )


def _has_default(groups: Dict[str, List[Tuple[str, str]]]) -> bool:
    return "0.0.0.0/0" in groups or "::/0" in groups


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
    except ValueError:
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


def _explicit_downstream_route_groups(
    node: Dict[str, Any],
    iface: Dict[str, Any],
    eth: str,
    family: int,
) -> Dict[str, List[PolicyHop]]:
    routes = _route_lists(iface)
    source = routes["ipv4"] if family == 4 else routes["ipv6"]
    groups: Dict[str, List[PolicyHop]] = {}
    for route in source:
        if route.get("policyOnly") is True:
            continue
        dst = _dst(route)
        if not dst or _is_default(dst):
            continue
        via = (
            _effective_via4(node, iface, route)
            if family == 4
            else _effective_via6(node, iface, route)
        )
        _append_policy_route(groups, dst, via, eth)
    return groups


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    # Phase 1: collect lane data for all lanes that have policy routes.
    # Each entry: (slot, table_id, priority, main_suppress_priority,
    # lane_ifnames, shared_ifnames, routes4, routes6)
    lanes: List[Tuple[int, int, int, int | None, List[str], List[str], Dict, Dict]] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None or not _is_policy_routing_surface(iface):
            continue

        routes4, routes6 = _policy_groups_for_lane(node, eth_map, ifname, iface)
        # Do NOT skip lanes with empty routes — deny-by-default lanes
        # must still get an ip rule so the kernel can route (to blackhole)
        # instead of generating ICMP "Network Unreachable" before nftables
        # policy drop can act.  (FS-170 silent-drop / D9)

        slot = _table_slot(eth_map, eth)
        table_id, priority, main_suppress_priority = _policy_routing_allocation(iface, ifname)
        source_ifnames: List[str] = []
        for source in _source_interfaces_for_lane(node, eth_map, ifname, iface):
            if eth_map.get(source) is not None:
                source_ifnames.append(source)

        lane_ifnames = [ifname]
        shared_ifnames = [s for s in source_ifnames if s != ifname]
        lanes.append((slot, table_id, priority, main_suppress_priority, lane_ifnames, shared_ifnames, routes4, routes6))

    # Phase 2: render policy tables and generic iif rules (order-independent).
    # Skip generic iif rules for access-uplink interfaces — their return-path
    # routing is handled by Phase 4 cross-rules (SMS-101).
    for _slot, table_id, priority, main_suppress_priority, lane_ifnames, shared_ifnames, routes4, routes6 in lanes:
        # Find whether this lane is an access-uplink (US-facing) interface
        is_uplink = False
        for ifname in lane_ifnames:
            source_eth = eth_map.get(ifname)
            if source_eth is None:
                continue
            iface = node.get("interfaces", {}).get(ifname, {})
            lane = _lane(iface)
            if lane.get("kind") == "access-uplink":
                is_uplink = True
            if is_uplink:
                break

        if routes4 != {}:
            _render_policy_table(cmds, "ip", table_id, routes4)
            if not is_uplink or _has_default(routes4):
                rule_ifnames = lane_ifnames if is_uplink else lane_ifnames + shared_ifnames
                for source_ifname in rule_ifnames:
                    source_eth = eth_map.get(source_ifname)
                    source_iface = (node.get("interfaces", {}) or {}).get(source_ifname, {})
                    if source_eth is None or not isinstance(source_iface, dict):
                        continue
                    _append_policy_rule_commands(
                        cmds,
                        ip_cmd="ip",
                        table_id=table_id,
                        priority=priority,
                        main_suppress_priority=main_suppress_priority,
                        source_iface=source_iface,
                        source_eth=source_eth,
                        family=4,
                        allow_unscoped=source_ifname in lane_ifnames,
                    )
        elif not is_uplink:
            # Deny-by-default lane: add blackhole default so the kernel
            # can route silently instead of generating ICMP (FS-170/D9).
            cmds.append(
                f"sh -c 'ip route replace table {table_id} blackhole 0.0.0.0/0 2>/dev/null || true'"
            )
            for source_ifname in lane_ifnames:
                source_eth = eth_map.get(source_ifname)
                if source_eth is None:
                    continue
                cmds.append(
                    f"sh -c 'ip rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )
        if routes6 != {}:
            _render_policy_table(cmds, "ip -6", table_id, routes6)
            if not is_uplink or _has_default(routes6):
                rule_ifnames = lane_ifnames if is_uplink else lane_ifnames + shared_ifnames
                for source_ifname in rule_ifnames:
                    source_eth = eth_map.get(source_ifname)
                    source_iface = (node.get("interfaces", {}) or {}).get(source_ifname, {})
                    if source_eth is None or not isinstance(source_iface, dict):
                        continue
                    _append_policy_rule_commands(
                        cmds,
                        ip_cmd="ip -6",
                        table_id=table_id,
                        priority=priority,
                        main_suppress_priority=main_suppress_priority,
                        source_iface=source_iface,
                        source_eth=source_eth,
                        family=6,
                        allow_unscoped=source_ifname in lane_ifnames,
                    )
        elif routes4 == {} and not is_uplink:
            # Deny-by-default lane: add IPv6 ip rule too.
            for source_ifname in lane_ifnames:
                source_eth = eth_map.get(source_ifname)
                if source_eth is None:
                    continue
                cmds.append(
                    f"sh -c 'ip -6 rule add iif {source_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                )

    # Phase 3: shared-interface destination-based rules.
    # Process lanes in DESCENDING priority order so higher-priority-number
    # lanes (generic uplinks like provider-handoff) claim destinations on
    # shared interfaces first. Lower-priority-number lanes (specific
    # access-node lanes like guest, client, trusted) process second and
    # have lower rule priority numbers, giving their rules HIGHER
    # precedence at evaluation time.
    # SMS-100: "Ensure lower-priority-number lanes do not capture
    # higher-priority-number lane traffic."
    claimed4: Set[Tuple[str, str]] = set()  # (dst, src_eth)
    claimed6: Set[Tuple[str, str]] = set()

    # Sort by priority descending (highest number first) — only for Phase 3.
    # Generic uplinks claim first so their destinations are reserved before
    # specific access-node lanes process. Access-node rules still have lower
    # priority numbers (higher precedence), but they won't claim destinations
    # that generic uplinks already reserved.
    sorted_lanes_asc = sorted(lanes, key=lambda x: x[2], reverse=True)

    for _slot, table_id, priority, _main_suppress_priority, _lane_ifnames, shared_ifnames, routes4, routes6 in sorted_lanes_asc:
        if routes4 != {} and shared_ifnames:
            for dst in sorted(routes4.keys()):
                if dst == "0.0.0.0/0":
                    continue
                for src_ifname in shared_ifnames:
                    src_eth = eth_map.get(src_ifname)
                    if src_eth is None:
                        continue
                    if (dst, src_eth) in claimed4:
                        continue
                    claimed4.add((dst, src_eth))
                    cmds.append(
                        f"sh -c 'ip rule add to {dst} iif {src_eth} priority {priority} table {table_id} 2>/dev/null || true'"
                    )
        if routes6 != {} and shared_ifnames:
            for dst in sorted(routes6.keys()):
                if dst == "::/0":
                    continue
                for src_ifname in shared_ifnames:
                    src_eth = eth_map.get(src_ifname)
                    if src_eth is None:
                        continue
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

    for _slot, table_id, priority, _main_suppress_priority, lane_ifnames, _shared_ifnames, routes4, routes6 in sorted_lanes_desc:
        if routes4 == {} and routes6 == {}:
            continue
        for ifname in lane_ifnames:
            eth = eth_map.get(ifname)
            if eth is None:
                continue
            iface = node.get("interfaces", {}).get(ifname, {})
            lane = _lane(iface)
            access = _lane_access(lane)
            kind = lane.get("kind")
            if access is None:
                continue
            lane_eths = [eth_map[name] for name in lane_ifnames if eth_map.get(name) is not None]
            if kind in ("access-uplink", "access"):
                upstream_by_access.setdefault(access, []).append(
                    (table_id, priority, lane_eths)
                )
            if kind in ("access", "access-edge"):
                downstream_by_access.setdefault(access, []).append(
                    (table_id, priority, routes4, routes6, iface, eth)
                )

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
                downstream_routes4 = dict(routes4)
                for dst, hops in _explicit_downstream_route_groups(node, ds_iface, ds_eth, 4).items():
                    for hop in hops:
                        downstream_routes4.setdefault(dst, [])
                        if hop not in downstream_routes4[dst]:
                            downstream_routes4[dst].append(hop)
                downstream_routes6 = dict(routes6)
                for dst, hops in _explicit_downstream_route_groups(node, ds_iface, ds_eth, 6).items():
                    for hop in hops:
                        downstream_routes6.setdefault(dst, [])
                        if hop not in downstream_routes6[dst]:
                            downstream_routes6[dst].append(hop)
                if downstream_routes4:
                    for dst in sorted(downstream_routes4.keys()):
                        if dst == "0.0.0.0/0":
                            continue
                        for via, eth in downstream_routes4[dst]:
                            cmds.append(
                                f"sh -c 'ip route replace table {us_table} {dst} via {via} dev {eth} onlink 2>/dev/null || true'"
                            )
                if downstream_routes6:
                    for dst in sorted(downstream_routes6.keys()):
                        if dst == "::/0":
                            continue
                        for via, eth in downstream_routes6[dst]:
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
