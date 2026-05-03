from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.cpm_solver import control_plane_model_to_solver_json
from clabgen.site_validation import (
    extract_enterprise_sites,
    validate_routing_assumptions,
    validate_site_invariants,
)
from clabgen.solver_json import parse_json_candidates


def load_solver(path: Path) -> Dict[str, Any]:
    raw = path.read_text()
    parsed = parse_json_candidates(path, raw)

    if "control_plane_model" in parsed:
        return control_plane_model_to_solver_json(parsed)

    return parsed


__all__ = [
    "extract_enterprise_sites",
    "load_solver",
    "validate_routing_assumptions",
    "validate_site_invariants",
]
