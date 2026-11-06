from __future__ import annotations

import importlib
import sys
from pathlib import Path


def _load_parser():
    return importlib.import_module("clabgen.parse-solver-json")


def _validate_canonical_input(input_path: Path) -> None:
    """Require a canonical realization bundle JSON input.

    FS-310-HDS-040-SDS-010-SMS-100: CPM output is not a public renderer input.
    """
    if not input_path.exists():
        raise SystemExit(f"canonical bundle JSON not found: {input_path}")
    if input_path.suffix not in (".json",):
        raise SystemExit(
            "generate-clab-config.py requires a canonical realization bundle (.json), "
            f"got: {input_path}"
        )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: generate-clab-config.py <canonical-realization-bundle.json> <topology_out> <bridges_out>"
        )

    cpm_input_path = Path(sys.argv[1])
    topology_out = Path(sys.argv[2])
    bridges_out = Path(sys.argv[3])

    _validate_canonical_input(cpm_input_path)

    parser = _load_parser()
    parser.write_outputs(cpm_input_path, topology_out, bridges_out)


if __name__ == "__main__":
    main()
