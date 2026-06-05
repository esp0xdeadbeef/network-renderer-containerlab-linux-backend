from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.provenance_fields import (
    first_dict,
    load_json_object,
    renderer_lock_summary,
    safe_value,
    source_classes as extract_source_classes,
    upstream_locks,
)


def _target_host(renderer_inventory: Dict[str, Any]) -> str | None:
    containerlab = renderer_inventory.get("containerlab")
    if not isinstance(containerlab, dict):
        return None
    for key in ("targetHost", "deploymentHost", "host"):
        value = containerlab.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _allowed_logical_nodes(
    renderer_inventory: Dict[str, Any], target_host: str | None
) -> set[tuple[str, str, str]] | None:
    if target_host is None:
        return None
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
        if all(isinstance(item, str) and item for item in (enterprise, site, name)):
            allowed.add((enterprise, site, name))
    return allowed


def _runtime_target_selected(
    enterprise: str,
    site_name: str,
    runtime_target: Dict[str, Any],
    allowed: set[tuple[str, str, str]] | None,
) -> bool:
    if allowed is None:
        return True
    logical = runtime_target.get("logicalNode")
    if not isinstance(logical, dict):
        return False
    name = logical.get("name")
    return isinstance(name, str) and (enterprise, site_name, name) in allowed


def _derived_scope(
    cpm: Dict[str, Any], renderer_inventory: Dict[str, Any]
) -> Dict[str, Any]:
    data = cpm.get("data")
    if not isinstance(data, dict):
        return {}

    enterprises: list[str] = []
    sites: list[str] = []
    runtime_targets: list[str] = []
    target_host = _target_host(renderer_inventory)
    allowed = _allowed_logical_nodes(renderer_inventory, target_host)

    for enterprise, sites_obj in sorted(data.items()):
        if not isinstance(enterprise, str) or not isinstance(sites_obj, dict):
            continue
        enterprise_selected = False
        for site_name, site_obj in sorted(sites_obj.items()):
            if not isinstance(site_name, str) or not isinstance(site_obj, dict):
                continue
            site_ref = f"{enterprise}/{site_name}"
            site_selected = False
            rt_obj = site_obj.get("runtimeTargets")
            if not isinstance(rt_obj, dict):
                continue
            for name, runtime_target in sorted(rt_obj.items()):
                if not isinstance(runtime_target, dict):
                    continue
                if not _runtime_target_selected(
                    enterprise, site_name, runtime_target, allowed
                ):
                    continue
                site_selected = True
                enterprise_selected = True
                runtime_targets.append(f"{site_ref}/{name}")
            if site_selected:
                sites.append(site_ref)
        if enterprise_selected:
            enterprises.append(enterprise)

    result: Dict[str, Any] = {}
    if enterprises:
        result["enterprises"] = enterprises
    if sites:
        result["sites"] = sites
    if runtime_targets:
        result["runtimeTargets"] = runtime_targets
    if target_host is not None:
        result["targetHost"] = target_host
    if result:
        result["derivedFromInput"] = True
    return result


def build_provenance(
    solver_json: Path,
    topology_out: Path,
    bridges_out: Path,
    renderer_inventory: Dict[str, Any],
    renderer_meta: Dict[str, Any],
    repo_root: Path,
) -> Dict[str, Any]:
    parsed = load_json_object(solver_json)
    cpm = parsed.get("control_plane_model")
    if not isinstance(cpm, dict):
        cpm = {}
    meta = cpm.get("meta")
    if not isinstance(meta, dict):
        meta = {}

    requested = first_dict(meta.get("requested"), meta.get("request"))
    target = first_dict(requested.get("target"), meta.get("requestedTarget"))
    scope = first_dict(requested.get("scope"), meta.get("requestedScope"))
    derived_scope = _derived_scope(cpm, renderer_inventory)
    target_host = _target_host(renderer_inventory)
    if not target:
        target = {"renderer": "containerlab-linux"}
        if target_host is not None:
            target["targetHost"] = target_host
        target["derivedFromRenderer"] = True
    if not scope:
        scope = derived_scope

    source_classes = extract_source_classes(meta)
    missing_classes = [
        source_class
        for source_class in ("userIntent", "publicInventory", "protectedInventory")
        if source_class not in source_classes
    ]
    for optional_class in ("runtimeFacts", "validationContext"):
        if optional_class not in source_classes:
            missing_classes.append(f"{optional_class}:not-declared")

    provenance: Dict[str, Any] = {
        "renderer": renderer_meta,
        "input": {
            "kind": "control-plane-model" if cpm else "solver-json",
            "path": str(solver_json),
            "controlPlaneModelVersion": cpm.get("version"),
        },
        "output": {
            "kind": "containerlab-topology",
            "artifact": str(topology_out),
            "companionArtifacts": [str(bridges_out)],
        },
        "sources": {
            "sourceClasses": source_classes,
            "missingSourceClasses": missing_classes,
        },
        "requested": {
            "scope": safe_value(scope),
            "target": safe_value(target),
            "derivedScope": safe_value(derived_scope),
        },
        "locks": {
            "upstream": upstream_locks(meta),
            "renderer": renderer_lock_summary(repo_root),
        },
        "redaction": {
            "protectedValues": "redacted",
        },
    }

    baseline = meta.get("controlledBaseline") or meta.get("sourceBaseline")
    if baseline is not None:
        provenance["controlledBaseline"] = safe_value(baseline)

    return provenance
