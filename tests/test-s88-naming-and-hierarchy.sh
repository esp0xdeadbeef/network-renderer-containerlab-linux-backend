#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "$repo_root"
import ast
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
s88 = root / "clabgen" / "s88"
allowed_layer_dirs = {"CM", "EM", "Unit", "enterprise", "site"}
errors = []

for path in sorted(s88.rglob("*.py")):
    rel = path.relative_to(root)
    parts = rel.parts
    layer = parts[2] if len(parts) > 2 else ""
    stem = path.stem

    if layer not in allowed_layer_dirs:
        if layer == "solver.py":
            continue
        errors.append(f"{rel}: invalid S88 layer directory {layer!r}")

    if stem != "__init__" and not re.fullmatch(r"[a-z][a-z0-9_]*", stem):
        errors.append(f"{rel}: Python module name must be lowercase snake_case")

    tree = ast.parse(path.read_text(), filename=str(rel))
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            imported.append(node.module)
        elif isinstance(node, ast.Import):
            imported.extend(alias.name for alias in node.names)

    def imports(prefix):
        return any(mod == prefix or mod.startswith(prefix + ".") for mod in imported)

    if layer == "enterprise" and (
        imports("clabgen.s88.EM") or imports("clabgen.s88.CM") or imports("clabgen.s88.Unit")
    ):
        errors.append(f"{rel}: enterprise must call site/enterprise helpers, not EM/CM/Unit")

    if layer == "site" and (imports("clabgen.s88.enterprise") or imports("clabgen.s88.Unit")):
        errors.append(f"{rel}: site must not import enterprise or Unit compatibility layer")

    if layer == "EM" and (
        imports("clabgen.s88.enterprise") or imports("clabgen.s88.site") or imports("clabgen.s88.Unit")
    ):
        errors.append(f"{rel}: EM must call CM and role parsers only, not higher layers")

    if layer == "CM" and (
        imports("clabgen.s88.enterprise") or imports("clabgen.s88.site") or imports("clabgen.s88.EM")
    ):
        errors.append(f"{rel}: CM must not import enterprise/site/EM")

if errors:
    print("S88 naming/hierarchy violations:", file=sys.stderr)
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
