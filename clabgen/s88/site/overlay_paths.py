from __future__ import annotations

from typing import Any, Dict, List, Set, Tuple
from collections import deque
import json

from clabgen.models import SiteModel


def transport_overlay_specs(site: SiteModel) -> Dict[str, Dict[str, Any]]:
    transport = dict(site.raw_transport or {})
    overlays = transport.get("overlays", [])
    if isinstance(overlays, dict):
        result: Dict[str, Dict[str, Any]] = {}
        for overlay_name, overlay_obj in overlays.items():
            if (
                isinstance(overlay_name, str)
                and overlay_name
                and isinstance(overlay_obj, dict)
            ):
                normalized = dict(overlay_obj)
                normalized.setdefault("name", overlay_name)
                result[overlay_name] = normalized
        return result
    if not isinstance(overlays, list):
        return {}
    result: Dict[str, Dict[str, Any]] = {}
    for overlay in overlays:
        if not isinstance(overlay, dict):
            continue
        name = overlay.get("name")
        if isinstance(name, str) and name:
            result[name] = dict(overlay)
    return result


def string_list(value: Any) -> List[str]:
    if isinstance(value, str) and value:
        return [value]
    if not isinstance(value, list):
        return []
    result: List[str] = []
    for item in value:
        if isinstance(item, str) and item:
            result.append(item)
    return result


def single_string_or_only_item(value: Any) -> str | None:
    if isinstance(value, str) and value:
        return value
    values = string_list(value)
    if len(values) == 1:
        return values[0]
    return None


def overlay_terminates_on_required_interface(
    site: SiteModel,
    *,
    overlay_name: str,
    terminate_on: str,
) -> bool:
    node = site.nodes.get(terminate_on)
    if node is None:
        raise RuntimeError(
            f"overlay {overlay_name!r} terminateOn node {terminate_on!r} not found"
        )
    for iface in node.interfaces.values():
        if getattr(iface, "kind", None) != "overlay":
            continue
        if getattr(iface, "overlay", None) == overlay_name:
            return True
    return False


def adjacency(site: SiteModel) -> Dict[str, Set[str]]:
    graph: Dict[str, Set[str]] = {}
    for node_name in site.nodes.keys():
        graph[node_name] = set()
    for link in site.links.values():
        endpoint_node_names: List[str] = []
        for endpoint_node_name in link.endpoints.keys():
            if endpoint_node_name in site.nodes:
                endpoint_node_names.append(endpoint_node_name)
        for source_node_name in endpoint_node_names:
            graph.setdefault(source_node_name, set())
            for destination_node_name in endpoint_node_names:
                if destination_node_name != source_node_name:
                    graph[source_node_name].add(destination_node_name)
    return graph


def first_hop_from_policy(
    site: SiteModel,
    *,
    policy_node_name: str,
    target_node_name: str,
) -> str | None:
    if policy_node_name == target_node_name:
        return None
    graph = adjacency(site)
    if policy_node_name not in graph or target_node_name not in graph:
        return None

    queue: deque[str] = deque([policy_node_name])
    parents: Dict[str, str | None] = {policy_node_name: None}
    while queue:
        current = queue.popleft()
        if current == target_node_name:
            break
        for neighbor in sorted(graph.get(current, set())):
            if neighbor not in parents:
                parents[neighbor] = current
                queue.append(neighbor)
    if target_node_name not in parents:
        return None

    current = target_node_name
    prev = parents[current]
    while prev is not None and prev != policy_node_name:
        current = prev
        prev = parents[current]
    if prev == policy_node_name:
        return current
    return None


def policy_iface_for_peer(
    peer_map: List[Dict[str, Any]],
    peer_name: str,
) -> Tuple[str, str] | None:
    for peer in peer_map:
        if peer.get("peer_name") != peer_name:
            continue
        eth = peer.get("eth")
        if isinstance(eth, int):
            return (f"eth{eth}", str(peer.get("policy_iface") or ""))
    return None


def resolve_external_via_overlay(
    site: SiteModel,
    *,
    policy_node_name: str,
    peer_map: List[Dict[str, Any]],
    external: str,
) -> str | None:
    overlay = transport_overlay_specs(site).get(external)
    if overlay is None:
        return None
    terminate_on = single_string_or_only_item(overlay.get("terminateOn"))
    if not isinstance(terminate_on, str) or not terminate_on:
        raise RuntimeError(
            f"overlay {external!r} missing terminateOn\n"
            + json.dumps(overlay, indent=2)
        )
    must_traverse = set(string_list(overlay.get("mustTraverse")))
    if must_traverse and "policy" not in must_traverse:
        raise RuntimeError(
            f"overlay {external!r} does not require policy traversal\n"
            + json.dumps(overlay, indent=2)
        )
    if not overlay_terminates_on_required_interface(
        site, overlay_name=external, terminate_on=terminate_on
    ):
        raise RuntimeError(
            f"overlay {external!r} has no overlay interface on terminateOn node {terminate_on!r}"
        )
    first_hop = first_hop_from_policy(
        site, policy_node_name=policy_node_name, target_node_name=terminate_on
    )
    if first_hop is None:
        raise RuntimeError(
            f"no topology path from policy node {policy_node_name!r} to overlay terminateOn node {terminate_on!r}"
        )
    resolved = policy_iface_for_peer(peer_map, first_hop)
    if resolved is None:
        raise RuntimeError(
            f"no policy-facing interface found for first hop {first_hop!r} toward overlay {external!r}"
        )
    return resolved[0]
