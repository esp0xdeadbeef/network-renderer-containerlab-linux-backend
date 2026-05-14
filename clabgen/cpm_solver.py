from __future__ import annotations

from typing import Any, Dict

from clabgen.cpm_runtime import add_runtime_target
from clabgen.cpm_transit import add_transit_links


def control_plane_model_to_solver_json(root: Dict[str, Any]) -> Dict[str, Any]:
    cpm = root.get("control_plane_model")
    if not isinstance(cpm, dict):
        raise ValueError("'control_plane_model' must be an object")

    data = cpm.get("data")
    if not isinstance(data, dict):
        raise ValueError("'control_plane_model.data' must be an object")

    enterprise_out: Dict[str, Any] = {}

    for enterprise, sites_obj in data.items():
        if not isinstance(enterprise, str) or not enterprise:
            continue
        if not isinstance(sites_obj, dict):
            raise ValueError(f"control_plane_model.data.{enterprise} must be an object")

        site_out: Dict[str, Any] = {}
        for site_name, site_obj in sites_obj.items():
            if not isinstance(site_name, str) or not site_name:
                continue
            if not isinstance(site_obj, dict):
                raise ValueError(
                    f"control_plane_model.data.{enterprise}.{site_name} must be an object"
                )
            site_out[site_name] = cpm_site_to_solver_site(site_obj)

        enterprise_out[enterprise] = {"site": site_out}

    return {
        "enterprise": enterprise_out,
        "meta": {
            "control_plane_model": cpm.get("meta", {}),
            "control_plane_model_version": cpm.get("version"),
        },
    }


def cpm_site_to_solver_site(site: Dict[str, Any]) -> Dict[str, Any]:
    runtime_targets = site.get("runtimeTargets")
    if not isinstance(runtime_targets, dict):
        raise ValueError("control_plane_model site must include runtimeTargets object")

    nodes: Dict[str, Any] = {}
    links: Dict[str, Any] = {}
    link_bridges: Dict[str, str] = {}
    link_host_uplinks: Dict[str, Dict[str, Any]] = {}
    link_metadata: Dict[str, Dict[str, Any]] = {}

    for rt_name, runtime_target in runtime_targets.items():
        if not isinstance(runtime_target, dict):
            continue
        add_runtime_target(
            str(rt_name),
            runtime_target,
            nodes,
            links,
            link_bridges,
            link_host_uplinks,
            link_metadata,
        )

    add_transit_links(site, links, link_bridges, link_host_uplinks, link_metadata)

    out = dict(site)
    out["nodes"] = nodes
    out["links"] = links
    return out
