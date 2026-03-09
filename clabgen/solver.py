from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, Tuple


def load_solver(path: Path) -> Dict[str, Any]:
    with path.open() as f:
        data = json.load(f)

    if not isinstance(data, dict):
        raise ValueError("solver JSON top-level must be an object")

    return data


def extract_enterprise_sites(data: Dict[str, Any]) -> Iterable[Tuple[str, str, Dict[str, Any]]]:
    enterprise_root = data.get("enterprise")
    if not isinstance(enterprise_root, dict):
        raise ValueError("'enterprise' must be an object")

    for enterprise_name, enterprise_obj in enterprise_root.items():
        if not isinstance(enterprise_obj, dict):
            raise ValueError(f"enterprise.{enterprise_name} must be an object")

        site_root = enterprise_obj.get("site")
        if not isinstance(site_root, dict):
            raise ValueError(f"enterprise.{enterprise_name}.site must be an object")

        for site_name, site_obj in site_root.items():
            if not isinstance(site_obj, dict):
                raise ValueError(
                    f"enterprise.{enterprise_name}.site.{site_name} must be an object"
                )
            yield enterprise_name, site_name, site_obj


def validate_site_invariants(site: Dict[str, Any], context: Dict[str, str] | None = None) -> None:
    ctx = context or {}

    if "nodes" not in site or "links" not in site:
        raise ValueError(
            f"Invalid site schema for {ctx}: missing 'nodes' or 'links'"
        )

    if not isinstance(site.get("nodes"), dict):
        raise ValueError(f"Invalid site schema for {ctx}: 'nodes' must be an object")

    if not isinstance(site.get("links"), dict):
        raise ValueError(f"Invalid site schema for {ctx}: 'links' must be an object")

    if "coreNodeNames" in site and not isinstance(site.get("coreNodeNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'coreNodeNames' must be an array"
        )

    if "uplinkCoreNames" in site and not isinstance(site.get("uplinkCoreNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'uplinkCoreNames' must be an array"
        )

    if "uplinkNames" in site and not isinstance(site.get("uplinkNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'uplinkNames' must be an array"
        )

    if "tenantPrefixOwners" in site and not isinstance(site.get("tenantPrefixOwners"), dict):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'tenantPrefixOwners' must be an object"
        )

    if "policyNodeName" in site and not isinstance(site.get("policyNodeName"), str):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'policyNodeName' must be a string"
        )

    if "upstreamSelectorNodeName" in site and not isinstance(site.get("upstreamSelectorNodeName"), str):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'upstreamSelectorNodeName' must be a string"
        )


def validate_routing_assumptions(site: Dict[str, Any]) -> Dict[str, Any]:
    _ = site
    return {
        "singleAccess": ""
    }
