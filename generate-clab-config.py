from __future__ import annotations

import importlib
import sys
from pathlib import Path


def _load_parser():
    return importlib.import_module("clabgen.parse-solver-json")


def _validate_cpm_input(cpm_input_path: Path) -> None:
    """Require a CPM JSON input file.  Refuse .nix and other non-JSON inputs."""
    if not cpm_input_path.exists():
        raise SystemExit(f"CPM JSON not found: {cpm_input_path}")
    if cpm_input_path.suffix not in (".json",):
        raise SystemExit(
            f"generate-clab-config.py requires CPM JSON input (.json), got: {cpm_input_path}"
        )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: generate-clab-config.py <control-plane-model.json> <topology_out> <bridges_out>"
        )

    cpm_input_path = Path(sys.argv[1])
    topology_out = Path(sys.argv[2])
    bridges_out = Path(sys.argv[3])

    _validate_cpm_input(cpm_input_path)

    parser = _load_parser()
    parser.write_outputs(cpm_input_path, topology_out, bridges_out)


if __name__ == "__main__":
    main()
