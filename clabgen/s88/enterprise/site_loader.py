from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.site.model_builder import (
    build_links,
    build_nodes,
    tenant_prefix_owners,
)
from clabgen.s88.enterprise.reservations import reject_unsupported_reservations
from clabgen.solver import (
    extract_enterprise_sites,
    load_solver,
    validate_routing_assumptions,
    validate_site_invariants,
)


def _transport(site: Dict[str, Any]) -> Dict[str, Any]:
    raw_transport = dict(site.get("transport", {}) or {})
    if "overlays" not in raw_transport:
        overlays = site.get("overlays")
        if isinstance(overlays, dict) and overlays:
            raw_transport["overlays"] = overlays
    return raw_transport


def _policy(site: Dict[str, Any]) -> Dict[str, Any]:
    raw_policy = dict(site.get("communicationContract", {}) or {})
    site_policy = site.get("policy")
    if not isinstance(site_policy, dict):
        return raw_policy

    for key in ("endpointBindings", "interfaceTags"):
        value = site_policy.get(key)
        if isinstance(value, dict):
            raw_policy[key] = value
    return raw_policy


def _target_host(renderer_inventory: Dict[str, Any]) -> str | None:
    containerlab = renderer_inventory.get("containerlab")
    if not isinstance(containerlab, dict):
        return None
    for key in ("targetHost", "deploymentHost", "host"):
        value = containerlab.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _logical_nodes_for_host(
    renderer_inventory: Dict[str, Any], target_host: str
) -> set[tuple[str, str, str]]:
    realization = renderer_inventory.get("realization")
    if not isinstance(realization, dict):
        return set()
    nodes = realization.get("nodes")
    if not isinstance(nodes, dict):
        return set()

    allowed: set[tuple[str, str, str]] = set()
    for node in nodes.values():
        if not isinstance(node, dict) or node.get("host") != target_host:
            continue
        logical = node.get("logicalNode")
        if not isinstance(logical, dict):
            continue
        enterprise = logical.get("enterprise")
        site = logical.get("site")
        name = logical.get("name")
        if (
            isinstance(enterprise, str)
            and isinstance(site, str)
            and isinstance(name, str)
        ):
            allowed.add((enterprise, site, name))
    return allowed


def _filter_site_to_target_host(
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


def load_sites(
    path: str | Path,
    renderer_inventory: Dict[str, Any] | None = None,
) -> Dict[str, SiteModel]:
    data = load_solver(Path(path))
    result: Dict[str, SiteModel] = {}
    solver_meta = dict(data.get("meta", {}) or {})
    renderer_inventory = dict(renderer_inventory or {})
    target_host = _target_host(renderer_inventory)
    allowed_logical_nodes = (
        _logical_nodes_for_host(renderer_inventory, target_host)
        if target_host is not None
        else None
    )
    if target_host is not None and not allowed_logical_nodes:
        raise ValueError(
            "containerlab renderer targetHost "
            f"'{target_host}' matched zero inventory realization nodes"
        )

    for enterprise, site_name, site in extract_enterprise_sites(data):
        filtered_site = _filter_site_to_target_host(
            enterprise, site_name, site, allowed_logical_nodes
        )
        if filtered_site is None:
            continue
        site = filtered_site
        reject_unsupported_reservations(site)
        validate_site_invariants(
            site,
            context={"enterprise": enterprise, "site": site_name},
        )
        for field_name in ("upstreamEmulation", "providerAccess"):
            if field_name in site:
                raise ValueError(f"CPM field {field_name} is not supported")

        assumptions = validate_routing_assumptions(site)
        owners = tenant_prefix_owners(site)
        key = f"{enterprise}-{site_name}"

        result[key] = SiteModel(
            enterprise=enterprise,
            site=site_name,
            nodes=build_nodes(site, owners),
            links=build_links(site),
            single_access=assumptions.get("singleAccess", ""),
            domains=dict(site.get("domains", {}) or {}),
            raw_policy=_policy(site),
            raw_nat={},
            raw_links=dict(site.get("links", {}) or {}),
            raw_ownership=dict(site.get("ownership", {}) or {}),
            raw_domains=dict(site.get("domains", {}) or {}),
            raw_transport=_transport(site),
            renderer_inventory=renderer_inventory,
            provider_zone_map={},
            solver_meta=solver_meta,
            policy_node_name=str(site.get("policyNodeName", "") or ""),
            upstream_selector_node_name=str(
                site.get("upstreamSelectorNodeName", "") or ""
            ),
            tenant_prefix_owners=owners,
        )

    if target_host is not None and not result:
        raise ValueError(
            "containerlab renderer targetHost "
            f"'{target_host}' selected zero runtime targets"
        )

    return result
