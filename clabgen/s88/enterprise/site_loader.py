from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.site.model_builder import (
    build_links,
    build_nodes,
    tenant_prefix_owners,
)
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


def load_sites(
    path: str | Path,
    renderer_inventory: Dict[str, Any] | None = None,
) -> Dict[str, SiteModel]:
    data = load_solver(Path(path))
    result: Dict[str, SiteModel] = {}
    solver_meta = dict(data.get("meta", {}) or {})
    renderer_inventory = dict(renderer_inventory or {})

    for enterprise, site_name, site in extract_enterprise_sites(data):
        validate_site_invariants(
            site,
            context={"enterprise": enterprise, "site": site_name},
        )

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

    return result
