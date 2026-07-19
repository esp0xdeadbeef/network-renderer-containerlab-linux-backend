from __future__ import annotations

import shlex
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


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _has_policy_routing_allocation(node: Dict[str, Any]) -> bool:
    for iface in _dict(node.get("interfaces")).values():
        if isinstance(iface, dict) and isinstance(iface.get("policyRoutingAllocation"), dict):
            return True
    return False


def _main_default_routes_allowed(node: Dict[str, Any]) -> bool:
    role = node.get("role", "")
    if role in ("downstream-selector", "upstream-selector"):
        return True

    routing_authority = _dict(node.get("routingAuthority"))
    if routing_authority.get("exitsSite") is True:
        return True
    if (
        routing_authority.get("defaultReachability") is False
        and _has_policy_routing_allocation(node)
    ):
        return False
    return True


def _main_default_route_allowed(
    node: Dict[str, Any],
    iface: Dict[str, Any],
    route: Dict[str, Any],
) -> bool:
    role = node.get("role", "")
    if role in ("downstream-selector", "upstream-selector"):
        return True
    if not _main_default_routes_allowed(node):
        return False

    intent = _dict(route.get("intent"))
    interface_class = _dict(iface.get("interfaceClass"))
    if (
        intent.get("kind") == "default-reachability"
        and isinstance(iface.get("policyRoutingAllocation"), dict)
        and interface_class.get("exitFacing") is not True
    ):
        return False
    return True


def _render_static_routes(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    routes4: Dict[str, List[Tuple[str, str]]] = {}
    routes6: Dict[str, List[Tuple[str, str]]] = {}
    connected4, connected6 = _connected_prefixes(node)
    local4, local6 = _local_ips(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for route in routes["ipv4"]:
            if route.get("policyOnly") is True:
                continue
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
                    via_cmd = f"ip route replace {via_host} dev {eth}"
                    if via_cmd not in seen:
                        seen.add(via_cmd)
                        cmds.append(via_cmd)

            _add_route(routes4, dst, via, eth)

        for route in routes["ipv6"]:
            if route.get("policyOnly") is True:
                continue
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
                    via_cmd = f"ip -6 route replace {via_host} dev {eth}"
                    if via_cmd not in seen:
                        seen.add(via_cmd)
                        cmds.append(via_cmd)

            _add_route(routes6, dst, via, eth)

    _append_route_groups(cmds, seen, "ip", routes4)
    _append_route_groups(cmds, seen, "ip -6", routes6)
    return cmds


def _render_runtime_delegated_routes(
    node: Dict[str, Any], eth_map: Dict[str, str]
) -> List[str]:
    commands: List[str] = []
    seen: set[Tuple[Any, ...]] = set()
    table_ids = sorted(
        {
            allocation["tableId"]
            for iface in _dict(node.get("interfaces")).values()
            if isinstance(iface, dict)
            for allocation in [iface.get("policyRoutingAllocation")]
            if isinstance(allocation, dict)
            and isinstance(allocation.get("tableId"), int)
            and allocation["tableId"] > 0
        }
    )

    for ifname in sorted(_dict(node.get("interfaces"))):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if not isinstance(iface, dict) or eth is None:
            continue
        for route in _route_lists(iface)["ipv6"]:
            intent = _dict(route.get("intent"))
            if intent.get("kind") != "runtime-routed-prefix-return":
                continue

            source_file = route.get("sourceFile")
            delegated_length = route.get("delegatedPrefixLength")
            tenant_length = route.get("perTenantPrefixLength")
            slot = route.get("slot")
            via = _effective_via6(node, iface, route)
            if (
                not isinstance(source_file, str)
                or not source_file.startswith("/run/secrets/")
                or source_file == "/run/secrets/"
                or "/../" in source_file
                or not isinstance(delegated_length, int)
                or not isinstance(tenant_length, int)
                or not isinstance(slot, int)
            ):
                raise ValueError(
                    "FS-350-HDS-010-SDS-010-SMS-060: incomplete protected "
                    "runtime IPv6 route contract"
                )

            key = (
                source_file,
                delegated_length,
                tenant_length,
                slot,
                via,
                eth,
                tuple(table_ids),
            )
            if key in seen:
                continue
            seen.add(key)

            materializer = " ".join(
                [
                    "clab-protected-ipv6-materializer",
                    "--source",
                    shlex.quote(source_file),
                    "--delegated-prefix-length",
                    str(delegated_length),
                    "--tenant-prefix-length",
                    str(tenant_length),
                    "--slot",
                    str(slot),
                ]
            )
            route_suffix = (
                f"via {shlex.quote(via)} dev {shlex.quote(eth)} onlink"
                if isinstance(via, str) and via
                else f"dev {shlex.quote(eth)}"
            )
            script = [
                "set -eu",
                f'runtime_prefix="$({materializer})"',
                f'ip -6 route replace "$runtime_prefix" {route_suffix}',
            ]
            script.extend(
                f'ip -6 route replace table {table_id} "$runtime_prefix" {route_suffix}'
                for table_id in table_ids
            )
            commands.append(f"sh -eu -c {shlex.quote(chr(10).join(script))}")

    return commands


def _render_default_routes(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    defaults4: Dict[str, List[Tuple[str, str]]] = {}
    defaults6: Dict[str, List[Tuple[str, str]]] = {}
    local4, local6 = _local_ips(node)
    main_defaults_allowed = _main_default_routes_allowed(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for route in routes["ipv4"]:
            if route.get("policyOnly") is True:
                continue
            if _dst(route) != "0.0.0.0/0":
                continue
            if not main_defaults_allowed or not _main_default_route_allowed(node, iface, route):
                continue
            if _route_via_is_local(route, 4, local4, local6):
                continue

            via = _effective_via4(node, iface, route)
            if via:
                _add_route(defaults4, "default", via, eth)

        for route in routes["ipv6"]:
            if route.get("policyOnly") is True:
                continue
            if _dst(route) != "::/0":
                continue
            if not main_defaults_allowed or not _main_default_route_allowed(node, iface, route):
                continue
            if _route_via_is_local(route, 6, local4, local6):
                continue

            via = _effective_via6(node, iface, route)
            if via:
                _add_route(defaults6, "default", via, eth)

    # Fabric-chain default routes for selector nodes.
    # Per PBR design rule: selectors MUST have default routes even when
    # CPM routingAuthority.defaultReachability=false.
    role = node.get("role", "")
    if role in ("downstream-selector", "upstream-selector") and not defaults4:
        forwarding_intent = node.get("forwardingIntent") or {}
        forwarding_rules = forwarding_intent.get("rules", []) or []
        for rule in forwarding_rules:
            if not isinstance(rule, dict):
                continue
            eg = _dict(rule.get("candidateEgress"))
            br = _dict(eg.get("backingRef"))
            lane = _dict(br.get("lane"))
            purpose = lane.get("kind", "")
            # For downstream-selector: find the interface toward policy
            # For upstream-selector: find the interface toward core
            from_if = rule.get("fromInterface", "")
            to_if = rule.get("toInterface", "")
            if role == "downstream-selector" and "policy" in to_if:
                from_eth = eth_map.get(from_if)
                to_eth = eth_map.get(to_if)
                if from_eth and to_eth:
                    # The peer IP on the link toward policy
                    from_iface = (node.get("interfaces", {}) or {}).get(from_if, {})
                    peer_addr = None
                    if isinstance(from_iface, dict):
                        addr4 = from_iface.get("addr4", "")
                        if isinstance(addr4, str) and "/" in addr4:
                            parts = addr4.split("/")
                            prefix = parts[0].split(".")
                            if len(prefix) == 4:
                                # Compute peer address: same /31
                                host = int(prefix[3])
                                peer_host = host + 1 if host % 2 == 0 else host - 1
                                peer_addr = f"{prefix[0]}.{prefix[1]}.{prefix[2]}.{peer_host}"
                    if peer_addr:
                        _add_route(defaults4, "default", peer_addr, to_eth)
            elif role == "upstream-selector" and ("upstream-vlan4" in to_if or "core-upstream" in to_if):
                from_eth = eth_map.get(from_if)
                to_eth = eth_map.get(to_if)
                if from_eth and to_eth:
                    # Use TO interface (core-facing) for peer address,
                    # not FROM interface (policy-facing). The nexthop
                    # toward internet is the core's p2p address, not
                    # the policy's address.
                    to_iface = (node.get("interfaces", {}) or {}).get(to_if, {})
                    peer_addr = None
                    if isinstance(to_iface, dict):
                        addr4 = to_iface.get("addr4", "")
                        if isinstance(addr4, str) and "/" in addr4:
                            parts = addr4.split("/")
                            prefix = parts[0].split(".")
                            if len(prefix) == 4:
                                host = int(prefix[3])
                                peer_host = host + 1 if host % 2 == 0 else host - 1
                                peer_addr = f"{prefix[0]}.{prefix[1]}.{prefix[2]}.{peer_host}"
                    if peer_addr:
                        _add_route(defaults4, "default", peer_addr, to_eth)

    _append_route_groups(cmds, seen, "ip", defaults4)
    _append_route_groups(cmds, seen, "ip -6", defaults6)
    return cmds


def _add_route(
    groups: Dict[str, List[Tuple[str, str]]],
    dst: str,
    via: str,
    eth: str,
) -> None:
    nexthops = groups.setdefault(dst, [])
    hop = (via, eth)
    if hop not in nexthops:
        nexthops.append(hop)


def _append_route_groups(
    cmds: List[str],
    seen: set[str],
    ip_cmd: str,
    groups: Dict[str, List[Tuple[str, str]]],
) -> None:
    def sort_nexthop(item: Tuple[str, str]) -> Tuple[str, str]:
        via, eth = item
        return eth, via

    for dst in sorted(groups.keys()):
        nexthops = groups[dst]
        if len(nexthops) == 1:
            via, eth = nexthops[0]
            cmd = f"{ip_cmd} route replace {dst} via {via} dev {eth} onlink"
        else:
            parts = [f"{ip_cmd} route replace {dst}"]
            for via, eth in sorted(nexthops, key=sort_nexthop):
                parts.append(f"nexthop via {via} dev {eth} onlink")
            cmd = " ".join(parts)
        if cmd not in seen:
            seen.add(cmd)
            cmds.append(cmd)
