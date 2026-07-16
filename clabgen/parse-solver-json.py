from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict

import yaml

from clabgen.provenance import build_provenance
from clabgen.provenance_fields import renderer_source_identity
from clabgen.s88.site.node_runtime import (
    collect_selector_relation_audit_sidecar,
    selector_relation_audit_sidecar_path,
)
from clabgen.solver import load_solver
from clabgen.s88.enterprise.enterprise import Enterprise


def _render_meta_comment(meta: Dict[str, Any]) -> str:
    lines = ["# --- provenance ---"]
    for line in json.dumps(meta, indent=2, sort_keys=True).splitlines():
        lines.append(f"# {line}")
    lines.append("# --- end provenance ---")
    return "\n".join(lines)


def _load_renderer_inventory_for_input(input_path: Path) -> Dict[str, Any]:
    """
    Renderer inventory must come from the input being rendered.

    We intentionally do *not* depend on local, mutable repo files (like a
    checked-in renderer-inputs.json), so tests and runs remain flake-locked and
    reproducible.
    """

    env_path = os.environ.get("CLABGEN_RENDERER_INVENTORY_JSON", "").strip()
    if env_path:
        p = Path(env_path)
        data = json.loads(p.read_text())
        if not isinstance(data, dict):
            raise ValueError(
                f"CLABGEN_RENDERER_INVENTORY_JSON must contain a JSON object: {p}"
            )
        return _with_env_target_host(data)

    raw = input_path.read_text()
    parsed = json.loads(raw)

    if not isinstance(parsed, dict):
        return {}

    cpm = parsed.get("control_plane_model")
    if not isinstance(cpm, dict):
        return {}

    endpoint_inventory = cpm.get("endpointInventory")
    if not isinstance(endpoint_inventory, dict):
        return {}

    return _with_env_target_host(endpoint_inventory)


def _with_env_target_host(renderer_inventory: Dict[str, Any]) -> Dict[str, Any]:
    target_host = os.environ.get("CLABGEN_DEPLOYMENT_HOST", "").strip()
    if not target_host:
        return renderer_inventory

    result = dict(renderer_inventory)
    containerlab = dict(result.get("containerlab", {}) or {})
    containerlab.setdefault("targetHost", target_host)
    result["containerlab"] = containerlab
    return result


def render_topology(
    solver_json: str | Path,
    renderer_inventory: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[1]
    solver_path = Path(solver_json)
    if renderer_inventory is None:
        renderer_inventory = _load_renderer_inventory_for_input(solver_path)

    enterprise = Enterprise.from_solver_json(
        solver_json,
        renderer_inventory=renderer_inventory,
    )
    rendered = enterprise.render()

    for link in rendered.get("topology", {}).get("links", []):
        endpoints = list(link.get("endpoints", []))
        labels = dict(link.get("labels", {}) or {})
        bridge = labels.get("clab.link.bridge")
        _ = endpoints
        _ = bridge

    return rendered


def _host_firewall_authority(
    renderer_inventory: Dict[str, Any],
) -> Dict[str, Any] | None:
    """
    FS-310-HDS-020-SDS-010-SMS-200: VM host-firewall enablement must trace to
    an explicit renderer inventory decision (`containerlab.hostFirewall`).

    Returns the explicit authority record when present, or None when the
    inventory is silent. A silent inventory emits no `hostFirewall` attribute
    into the generated bridges artifact, so the VM module fails closed instead
    of substituting a disabled-firewall convenience default. A malformed
    record is rejected here rather than propagated as an implicit decision.
    """

    containerlab = renderer_inventory.get("containerlab")
    if not isinstance(containerlab, dict):
        return None
    host_firewall = containerlab.get("hostFirewall")
    if host_firewall is None:
        return None
    if not isinstance(host_firewall, dict) or not isinstance(
        host_firewall.get("enable"), bool
    ):
        raise ValueError(
            "FS-310-HDS-020-SDS-010-SMS-200: renderer inventory "
            "containerlab.hostFirewall must be an object with a boolean "
            "'enable' field; refusing to emit an implicit host-firewall "
            "decision"
        )
    return host_firewall


def _render_bridges_body(
    bridges: list,
    bridge_networks: Dict[str, Any],
    lab_emulation_artifacts: list,
    host_firewall: Dict[str, Any] | None,
) -> str:
    host_firewall_block = ""
    if host_firewall is not None:
        host_firewall_block = (
            "  hostFirewall = builtins.fromJSON ''\n"
            + json.dumps(host_firewall, sort_keys=True)
            + "\n"
            "  '';\n"
        )

    return (
        "{ lib, ... }:\n"
        "{\n"
        "  bridges = [\n" + "\n".join(f'    "{b}"' for b in bridges) + "\n"
        "  ];\n"
        "  labEmulationArtifacts = builtins.fromJSON ''\n"
        + json.dumps(lab_emulation_artifacts, sort_keys=True)
        + "\n"
        "  '';\n"
        "  bridgeNetworks = builtins.fromJSON ''\n"
        + json.dumps(bridge_networks, sort_keys=True)
        + "\n"
        "  '';\n"
        + host_firewall_block
        + "}\n"
    )


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    solver_json = Path(solver_json)
    topology_out = Path(topology_out)
    bridges_out = Path(bridges_out)

    _ = load_solver(solver_json)

    renderer_inventory = _load_renderer_inventory_for_input(solver_json)
    merged = render_topology(solver_json, renderer_inventory=renderer_inventory)

    topology_doc = {
        "name": merged["name"],
        "topology": merged["topology"],
    }
    selector_audit_out = selector_relation_audit_sidecar_path(topology_out)
    selector_audit_sidecar = collect_selector_relation_audit_sidecar(
        topology_doc,
        sidecar_name=selector_audit_out.name,
    )

    topo_yaml = yaml.safe_dump(topology_doc, sort_keys=False)

    repo_root = Path(__file__).resolve().parents[1]

    renderer_meta = renderer_source_identity(repo_root)
    renderer_meta["schemaVersion"] = 3

    provenance = build_provenance(
        solver_json,
        topology_out,
        bridges_out,
        renderer_inventory,
        renderer_meta,
        repo_root,
    )

    comment = _render_meta_comment(provenance)

    topology_out.write_text(f"{comment}\n# fabric.clab.yml\n{topo_yaml}")
    if selector_audit_sidecar:
        selector_audit_out.write_text(
            json.dumps(selector_audit_sidecar, indent=2, sort_keys=True) + "\n"
        )
    elif selector_audit_out.exists():
        selector_audit_out.unlink()

    bridges = list(merged.get("bridges", []))
    bridge_networks = dict(merged.get("bridge_networks", {}) or {})
    lab_emulation_artifacts = list(merged.get("lab_emulation_artifacts", []) or [])
    host_firewall = _host_firewall_authority(renderer_inventory)

    bridges_body = _render_bridges_body(
        bridges,
        bridge_networks,
        lab_emulation_artifacts,
        host_firewall,
    )

    bridges_out.write_text(bridges_body)
