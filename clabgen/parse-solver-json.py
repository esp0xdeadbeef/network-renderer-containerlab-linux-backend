from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

import yaml

from clabgen.solver import load_solver
from clabgen.s88.enterprise.enterprise import Enterprise


def _git_rev(repo: Path) -> str:
    try:
        return (
            subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "HEAD"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
    except Exception:
        return "unknown"


def _git_dirty(repo: Path) -> bool:
    try:
        subprocess.check_call(
            ["git", "-C", str(repo), "diff", "--quiet"],
            stderr=subprocess.DEVNULL,
        )
        subprocess.check_call(
            ["git", "-C", str(repo), "diff", "--cached", "--quiet"],
            stderr=subprocess.DEVNULL,
        )
        return False
    except subprocess.CalledProcessError:
        return True


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
        try:
            data = json.loads(p.read_text())
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    try:
        raw = input_path.read_text()
        parsed = json.loads(raw)
    except Exception:
        return {}

    if not isinstance(parsed, dict):
        return {}

    cpm = parsed.get("control_plane_model")
    if not isinstance(cpm, dict):
        return {}

    endpoint_inventory = cpm.get("endpointInventory")
    if not isinstance(endpoint_inventory, dict):
        return {}

    return endpoint_inventory


def render_topology(solver_json: str | Path) -> Dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[1]
    solver_path = Path(solver_json)
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


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    solver_json = Path(solver_json)
    topology_out = Path(topology_out)
    bridges_out = Path(bridges_out)

    _ = load_solver(solver_json)

    merged = render_topology(solver_json)

    topo_yaml = yaml.safe_dump(
        {
            "name": merged["name"],
            "topology": merged["topology"],
        },
        sort_keys=False,
    )

    repo_root = Path(__file__).resolve().parents[1]

    renderer_meta = {
        "name": repo_root.name,
        "gitRev": _git_rev(repo_root),
        "gitDirty": _git_dirty(repo_root),
        "schemaVersion": 2,
    }

    provenance = {
        "renderer": renderer_meta,
    }

    comment = _render_meta_comment(provenance)

    topology_out.write_text(f"{comment}\n# fabric.clab.yml\n{topo_yaml}")

    bridges = list(merged.get("bridges", []))

    bridges_body = (
        "{ lib, ... }:\n"
        "{\n"
        "  bridges = [\n"
        + "\n".join(f'    "{b}"' for b in bridges)
        + "\n"
        "  ];\n"
        "}\n"
    )

    bridges_out.write_text(bridges_body)
