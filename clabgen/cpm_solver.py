from __future__ import annotations

from typing import Any, Dict

from clabgen.cpm_runtime import add_runtime_target
from clabgen.cpm_transit import add_transit_links


def _reservation_count(runtime_target: Dict[str, Any]) -> int:
    advertisements = runtime_target.get("advertisements")
    if not isinstance(advertisements, dict):
        return 0

    count = 0
    for family in ("dhcp4", "dhcpv6"):
        entries = advertisements.get(family)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            reservations = entry.get("reservations")
            if isinstance(reservations, list):
                count += len(reservations)
    return count


def _reject_unsupported_reservations(site: Dict[str, Any]) -> None:
    runtime_targets = site.get("runtimeTargets")
    if not isinstance(runtime_targets, dict):
        return

    for rt_name, runtime_target in runtime_targets.items():
        if not isinstance(runtime_target, dict):
            continue
        if _reservation_count(runtime_target) > 0:
            raise ValueError(
                "containerlab-linux renderer does not materialize DHCP reservations; "
                f"unsupported reservations present at runtimeTargets.{rt_name}.advertisements"
            )


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
    _reject_unsupported_reservations(site)

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

    forwarding_semantics = site.get("forwardingSemantics")
    if isinstance(forwarding_semantics, dict):
        semantic_nodes = forwarding_semantics.get("nodes")
        if isinstance(semantic_nodes, dict):
            for node_name, node_data in nodes.items():
                semantic_node = semantic_nodes.get(node_name)
                if not isinstance(semantic_node, dict):
                    continue
                egress_intent = semantic_node.get("egressIntent")
                if isinstance(egress_intent, dict):
                    node_data["egressIntent"] = dict(egress_intent)
                nat_intent = semantic_node.get("natIntent")
                if isinstance(nat_intent, dict):
                    node_data["natIntent"] = dict(nat_intent)

    add_transit_links(site, links, link_bridges, link_host_uplinks, link_metadata)

    out = dict(site)
    out["nodes"] = nodes
    out["links"] = links
    return out
