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


def _to_nix(value: Any, indent: int = 0) -> str:
    sp = " " * indent

    if value is None:
        return "null"

    if isinstance(value, bool):
        return "true" if value else "false"

    if isinstance(value, (int, float)):
        return str(value)

    if isinstance(value, str):
        return json.dumps(value)

    if isinstance(value, list):
        if not value:
            return "[ ]"
        inner = "\n".join(f'{" " * (indent + 2)}{_to_nix(item, indent + 2)}' for item in value)
        return "[\n" + inner + f"\n{sp}]"

    if isinstance(value, dict):
        if not value:
            return "{ }"
        parts = []
        for key in sorted(value.keys()):
            parts.append(f'{" " * (indent + 2)}{json.dumps(str(key))} = {_to_nix(value[key], indent + 2)};')
        return "{\n" + "\n".join(parts) + f"\n{sp}}}"

    raise TypeError(f"unsupported Nix conversion type: {type(value)!r}")


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
        "schemaVersion": 2,
    }

    provenance = {
        "renderer": renderer_meta,
        "solver": dict(solver.get("meta", {}) or {}),
    }

    comment = _render_meta_comment(provenance)

    topology_out.write_text(f"{comment}\n# fabric.clab.yml\n{topo_yaml}")

    bridge_modules = dict(merged.get("bridge_control_modules", {}) or {})
    bridges = list(merged.get("bridges", []))

    bridges_body = (
        "{ lib, ... }:\n"
        "{\n"
        f"  provenance = {_to_nix(provenance, 2)};\n"
        f"  bridges = {_to_nix(bridges, 2)};\n"
        f"  bridgeControlModules = {_to_nix(bridge_modules, 2)};\n"
        "}\n"
    )

    bridges_out.write_text(bridges_body)
