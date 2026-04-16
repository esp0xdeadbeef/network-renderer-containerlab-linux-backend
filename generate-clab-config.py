from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path


def _load_parser():
    return importlib.import_module("clabgen.parse-solver-json")


def _candidate_control_plane_model_paths(intent_path: Path) -> list[Path]:
    env_candidates: list[Path] = []

    for env_name in (
        "CLABGEN_CONTROL_PLANE_MODEL_JSON",
        "CONTROL_PLANE_MODEL_JSON",
        "SOLVER_JSON",
    ):
        raw = os.environ.get(env_name, "").strip()
        if raw:
            env_candidates.append(Path(raw))

    local_candidates = [
        intent_path.with_name("output-control-plane-model-signed.json"),
        intent_path.with_name("output-control-plane-model.json"),
        intent_path.with_name("control-plane-model.json"),
        intent_path.with_name("output-solver-signed.json"),
        intent_path.with_name("output-solver.json"),
    ]

    cwd = Path.cwd()
    cwd_candidates = [
        cwd / "output-control-plane-model-signed.json",
        cwd / "output-control-plane-model.json",
        cwd / "control-plane-model.json",
        cwd / "output-solver-signed.json",
        cwd / "output-solver.json",
    ]

    ordered: list[Path] = []
    seen: set[str] = set()

    for candidate in env_candidates + local_candidates + cwd_candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        ordered.append(candidate)

    return ordered


def _normalized_solver_input(input_path: Path) -> Path:
    if input_path.suffix != ".nix":
        return input_path

    for candidate in _candidate_control_plane_model_paths(input_path):
        if candidate.exists():
            return candidate

    searched = "\n".join(f"  - {candidate}" for candidate in _candidate_control_plane_model_paths(input_path))
    raise RuntimeError(
        "generate-clab-config.py does not parse intent.nix.\n"
        "Provide a prebuilt control-plane-model JSON and point to it directly, or place one at one of:\n"
        f"{searched}"
    )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: generate-clab-config.py <control-plane-model.json|intent.nix> <topology_out> <bridges_out>"
        )

    solver_json = Path(sys.argv[1])
    topology_out = Path(sys.argv[2])
    bridges_out = Path(sys.argv[3])

    parser = _load_parser()
    normalized_input = _normalized_solver_input(solver_json)
    parser.write_outputs(normalized_input, topology_out, bridges_out)


if __name__ == "__main__":
    main()
