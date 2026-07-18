from __future__ import annotations

import ipaddress
from typing import Any, Dict, List, Tuple

TRACE_ID = "FS-270-HDS-010-SDS-010-SMS-020"


def _contract_error(reason: str) -> ValueError:
    return ValueError(f"{TRACE_ID}: invalid relation policy selector: {reason}")


def _non_empty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise _contract_error(f"missing {field}")
    return value


def _positive_int(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise _contract_error(f"{field} must be a positive integer")
    return value


def _interfaces(node: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    interfaces = node.get("interfaces", {})
    if not isinstance(interfaces, dict):
        raise _contract_error("interfaces must be an object")
    if not all(
        isinstance(name, str) and isinstance(iface, dict)
        for name, iface in interfaces.items()
    ):
        raise _contract_error("interface entries must be named objects")
    return interfaces


def _interface_for_identity(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
    identity: Any,
    field: str,
) -> Tuple[str, str, Dict[str, Any]]:
    value = _non_empty_string(identity, field)
    matches: List[Tuple[str, str, Dict[str, Any]]] = []
    for logical, iface in _interfaces(node).items():
        target = eth_map.get(logical)
        declared = iface.get("runtimeIfName")
        if target is None:
            continue
        if value in {logical, target, declared}:
            matches.append((logical, target, iface))
    if len(matches) != 1:
        raise _contract_error(f"{field} must resolve to exactly one CPM interface")
    return matches[0]


def _prefix(value: Any, family: int, field: str) -> str:
    raw = _non_empty_string(value, field)
    try:
        network = ipaddress.ip_network(raw, strict=False)
    except ValueError as exc:
        raise _contract_error(f"{field} must be a valid family prefix") from exc
    if network.version != family:
        raise _contract_error(f"{field} family does not match selector family")
    if network.prefixlen == 0:
        raise _contract_error("default prefixes cannot grant transitive authority")
    return str(network)


def _route_matches_selector(
    route: Dict[str, Any],
    selector: Dict[str, Any],
    destination: str,
) -> bool:
    intent = route.get("intent")
    if not isinstance(intent, dict):
        return False
    route_destination = route.get("dst")
    try:
        normalized_route_destination = str(
            ipaddress.ip_network(route_destination, strict=False)
        )
    except (TypeError, ValueError):
        return False
    return (
        route.get("policyOnly") is True
        and normalized_route_destination == destination
        and route.get("relationId") == selector.get("relationId")
        and route.get("returnBehavior") == selector.get("returnBehavior")
        and route.get("trafficType") == selector.get("trafficType")
        and intent.get("kind") == "relation-policy-reachability"
        and intent.get("direction") == selector.get("direction")
        and intent.get("relationId") == selector.get("relationId")
        and intent.get("policyStateOwner") == selector.get("policyStateOwner")
    )


def _validate_selector(
    node: Dict[str, Any],
    eth_map: Dict[str, str],
    selector: Dict[str, Any],
) -> Dict[str, Any]:
    if selector.get("authority") != "relation-policy-state-owner":
        raise _contract_error("unsupported selector authority")
    family = selector.get("family")
    if family not in {4, 6}:
        raise _contract_error("family must be 4 or 6")
    direction = selector.get("direction")
    if direction not in {"forward", "return"}:
        raise _contract_error("direction must be forward or return")
    if selector.get("returnBehavior") != "symmetric":
        raise _contract_error("return behavior must preserve the policy state owner")

    relation_id = _non_empty_string(selector.get("relationId"), "relationId")
    state_owner = _non_empty_string(
        selector.get("policyStateOwner"), "policyStateOwner"
    )
    _non_empty_string(selector.get("service"), "service")
    _non_empty_string(selector.get("trafficType"), "trafficType")
    table_id = _positive_int(selector.get("tableId"), "tableId")
    priority = _positive_int(selector.get("priority"), "priority")
    _positive_int(selector.get("relationPriority"), "relationPriority")
    source = _prefix(selector.get("sourcePrefix"), family, "sourcePrefix")
    destination = _prefix(
        selector.get("destinationPrefix"), family, "destinationPrefix"
    )

    _, incoming_runtime, _ = _interface_for_identity(
        node, eth_map, selector.get("incomingInterface"), "incomingInterface"
    )
    _, _policy_runtime, policy_iface = _interface_for_identity(
        node, eth_map, selector.get("policyInterface"), "policyInterface"
    )
    allocation = policy_iface.get("policyRoutingAllocation")
    if not isinstance(allocation, dict):
        raise _contract_error("policy interface lacks a CPM table allocation")
    if allocation.get("source") != "control-plane-model":
        raise _contract_error("policy table allocation is not CPM-owned")
    if allocation.get("tableId") != table_id:
        raise _contract_error(
            "selector table differs from its policy interface allocation"
        )
    table_priority = _positive_int(
        allocation.get("tableRulePriority"), "policy table rule priority"
    )
    if priority >= table_priority:
        raise _contract_error("relation selector must precede the generic policy rule")

    routes = policy_iface.get("routes", {})
    family_routes = (
        routes.get("ipv4" if family == 4 else "ipv6", [])
        if isinstance(routes, dict)
        else []
    )
    if not isinstance(family_routes, list):
        raise _contract_error("policy interface routes must be family arrays")
    matches = [
        route
        for route in family_routes
        if isinstance(route, dict)
        and _route_matches_selector(route, selector, destination)
    ]
    if len(matches) != 1:
        raise _contract_error("selector requires exactly one bounded CPM policy route")

    return {
        "direction": direction,
        "family": family,
        "incomingRuntime": incoming_runtime,
        "policyStateOwner": state_owner,
        "priority": priority,
        "relationId": relation_id,
        "source": source,
        "destination": destination,
        "tableId": table_id,
    }


def _validate_direction_pairs(selectors: List[Dict[str, Any]]) -> None:
    groups: Dict[Tuple[str, int], List[Dict[str, Any]]] = {}
    for selector in selectors:
        groups.setdefault((selector["relationId"], selector["family"]), []).append(
            selector
        )
    for group in groups.values():
        directions = {selector["direction"] for selector in group}
        if directions != {"forward", "return"} or len(group) != 2:
            raise _contract_error(
                "each relation family requires one forward and one return selector"
            )
        forward = next(
            selector for selector in group if selector["direction"] == "forward"
        )
        returned = next(
            selector for selector in group if selector["direction"] == "return"
        )
        if (
            forward["source"] != returned["destination"]
            or forward["destination"] != returned["source"]
            or forward["policyStateOwner"] != returned["policyStateOwner"]
        ):
            raise _contract_error(
                "forward and return selectors do not share one policy state path"
            )


def render_relation_selection_rules(
    node: Dict[str, Any], eth_map: Dict[str, str]
) -> List[str]:
    raw_selectors = node.get("routeSelectionRules", [])
    if not isinstance(raw_selectors, list):
        raise _contract_error("routeSelectionRules must be an array")
    if not raw_selectors:
        return []
    if not all(isinstance(selector, dict) for selector in raw_selectors):
        raise _contract_error("routeSelectionRules entries must be objects")

    selectors = [
        _validate_selector(node, eth_map, selector) for selector in raw_selectors
    ]
    _validate_direction_pairs(selectors)

    commands: List[str] = []
    seen: set[str] = set()
    for selector in selectors:
        ip_cmd = "ip" if selector["family"] == 4 else "ip -6"
        command = f"sh -c '{ip_cmd} rule add from {selector['source']} to {selector['destination']} iif {selector['incomingRuntime']} priority {selector['priority']} table {selector['tableId']} 2>/dev/null || true'"
        if command not in seen:
            seen.add(command)
            commands.append(command)
    return commands
