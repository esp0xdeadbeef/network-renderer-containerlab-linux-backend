# ./clabgen/export.py
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Dict

import yaml

from clabgen.s88.enterprise.enterprise import Enterprise


def _git_rev(repo: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
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


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    solver_json = Path(solver_json)
    topology_out = Path(topology_out)
    bridges_out = Path(bridges_out)

    with solver_json.open() as f:
        solver = json.load(f)

    enterprise = Enterprise.from_solver_json(solver_json)
    merged = enterprise.render()

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
        "schemaVersion": 1,
    }

    provenance = {
        "renderer": renderer_meta,
    }

    comment = _render_meta_comment(provenance)

    topology_out.write_text(f"{comment}\n# fabric.clab.yml\n{topo_yaml}")

    bridges_out.write_text(
        "{ lib, ... }:\n{\n  bridges = [\n"
        + "\n".join(f'    "{b}"' for b in merged["bridges"])
        + "\n  ];\n}\n"
    )
