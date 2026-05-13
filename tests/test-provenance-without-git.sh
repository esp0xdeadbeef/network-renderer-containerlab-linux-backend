#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "${repo_root}"
import importlib.util
import subprocess
import sys
import types
from pathlib import Path
from unittest import mock

repo = Path(sys.argv[1])
module_path = repo / "clabgen" / "parse-solver-json.py"
spec = importlib.util.spec_from_file_location("parse_solver_json", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None

sys.modules["yaml"] = types.SimpleNamespace(safe_dump=lambda *_args, **_kwargs: "")
sys.modules["clabgen.solver"] = types.SimpleNamespace(load_solver=lambda *_args, **_kwargs: {})
sys.modules["clabgen.s88.enterprise.enterprise"] = types.SimpleNamespace(Enterprise=object)

spec.loader.exec_module(module)


def missing_git(*_args, **_kwargs):
    raise FileNotFoundError("git")


with mock.patch.object(subprocess, "check_call", side_effect=missing_git):
    assert module._git_dirty(repo) is True

print("PASS provenance-without-git")
PY
