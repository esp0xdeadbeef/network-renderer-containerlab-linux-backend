from __future__ import annotations

from typing import Any, Dict


def filter_site_to_target_host(
    enterprise: str,
    site_name: str,
    site: Dict[str, Any],
    allowed_logical_nodes: set[tuple[str, str, str]] | None,
) -> Dict[str, Any] | None:
    if allowed_logical_nodes is None:
        return site

    allowed_names: set[str] = set()
    for allowed_enterprise, allowed_site, node_name in allowed_logical_nodes:
        if allowed_enterprise == enterprise and allowed_site == site_name:
            allowed_names.add(node_name)
    if not allowed_names:
        return None

    filtered = dict(site)
    nodes = site.get("nodes")
    if isinstance(nodes, dict):
        filtered_nodes: Dict[str, Any] = {}
        for name, node in nodes.items():
            if name in allowed_names:
                filtered_nodes[name] = node
        filtered["nodes"] = filtered_nodes

    runtime_targets = site.get("runtimeTargets")
    if isinstance(runtime_targets, dict):
        filtered_runtime_targets: Dict[str, Any] = {}
        for name, target in runtime_targets.items():
            if not isinstance(target, dict):
                continue
            logical_node = target.get("logicalNode")
            if not isinstance(logical_node, dict):
                continue
            if logical_node.get("name") in allowed_names:
                filtered_runtime_targets[name] = target
        filtered["runtimeTargets"] = filtered_runtime_targets

    links = site.get("links")
    if isinstance(links, dict):
        filtered_links: Dict[str, Any] = {}
        for name, link in links.items():
            if not isinstance(link, dict):
                continue
            endpoints = link.get("endpoints")
            if not isinstance(endpoints, dict):
                continue
            all_endpoints_allowed = True
            for endpoint in endpoints.keys():
                if endpoint not in allowed_names:
                    all_endpoints_allowed = False
                    break
            if all_endpoints_allowed:
                filtered_links[name] = link
        filtered["links"] = filtered_links

    return filtered
