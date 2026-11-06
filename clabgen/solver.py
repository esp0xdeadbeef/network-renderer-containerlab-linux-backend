from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.canonical_bundle import control_plane_envelope, is_direct_cpm
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

    # FS-310-HDS-040-SDS-010-SMS-100: renderer input is one validated canonical
    # realization bundle. A raw CPM payload is rejected by the canonical gate;
    # the envelope inside the bundle is what the renderer projects.
    if isinstance(parsed, dict) and isinstance(parsed.get("network"), dict):
        return control_plane_model_to_solver_json(
            {"control_plane_model": control_plane_envelope(parsed)}
        )

    if is_direct_cpm(parsed):
        control_plane_envelope(parsed)  # raises the boundary diagnostic

    return parsed


__all__ = [
    "extract_enterprise_sites",
    "load_solver",
    "validate_routing_assumptions",
    "validate_site_invariants",
]
