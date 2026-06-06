#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "${repo_root}"
import importlib.util
import sys
import types
from pathlib import Path

repo = Path(sys.argv[1])
module_path = repo / "clabgen" / "parse-solver-json.py"
spec = importlib.util.spec_from_file_location("parse_solver_json", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None

sys.modules["yaml"] = types.SimpleNamespace(safe_dump=lambda *_args, **_kwargs: "")
sys.modules["clabgen.solver"] = types.SimpleNamespace(load_solver=lambda *_args, **_kwargs: {})
sys.modules["clabgen.s88.enterprise.enterprise"] = types.SimpleNamespace(Enterprise=object)

spec.loader.exec_module(module)

from clabgen.provenance_fields import renderer_source_identity

identity = renderer_source_identity(Path("/tmp/not-a-git-repo-for-clab-provenance"))
assert identity["rev"] == "unknown"
assert identity["dirty"] in {True, "unknown"}
assert identity["immutable"] is False

print("PASS provenance-without-git")
PY
