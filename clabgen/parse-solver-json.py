from __future__ import annotations

import json
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


def _load_renderer_inventory(base_dir: Path) -> Dict[str, Any]:
    inventory_file = base_dir / "renderer-inputs.json"

    if not inventory_file.exists():
        return {"hosts": {}}

    with inventory_file.open() as f:
        data = json.load(f)

    if not isinstance(data, dict):
        raise ValueError("renderer-inputs.json top-level must be an object")

    return data


def render_topology(solver_json: str | Path) -> Dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[1]
    renderer_inventory = _load_renderer_inventory(repo_root)

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
