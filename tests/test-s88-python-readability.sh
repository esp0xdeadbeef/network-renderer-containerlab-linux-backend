#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import ast
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
s88_root = repo_root / "clabgen" / "s88"
errors: list[str] = []


def target_names(target: ast.AST) -> list[str]:
    if isinstance(target, ast.Name):
        return [target.id]
    if isinstance(target, (ast.Tuple, ast.List)):
        result: list[str] = []
        for child in target.elts:
            result.extend(target_names(child))
        return result
    return []


for path in sorted(s88_root.rglob("*.py")):
    rel = path.relative_to(repo_root)
    tree = ast.parse(path.read_text(), filename=str(rel))

    for node in ast.walk(tree):
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            errors.append(f"{rel}:{node.lineno}: avoid compact comprehensions in S88 Python code")

        if isinstance(node, ast.Lambda):
            errors.append(f"{rel}:{node.lineno}: avoid lambda in S88 Python code")

        if isinstance(node, ast.NamedExpr):
            errors.append(f"{rel}:{node.lineno}: avoid assignment expressions in S88 Python code")

        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "next":
            errors.append(f"{rel}:{node.lineno}: avoid next() shortcuts in S88 Python code")

        if isinstance(node, (ast.For, ast.AsyncFor)):
            for name in target_names(node.target):
                if len(name) == 1 and name != "_":
                    errors.append(f"{rel}:{node.lineno}: loop variable {name!r} is too terse")

        if isinstance(node, ast.comprehension):
            for name in target_names(node.target):
                if len(name) == 1 and name != "_":
                    errors.append(f"{rel}:{node.lineno}: comprehension variable {name!r} is too terse")

        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets = [node.target] if hasattr(node, "target") else list(getattr(node, "targets", []))
            for target in targets:
                for name in target_names(target):
                    if len(name) == 1 and name != "_":
                        errors.append(f"{rel}:{node.lineno}: variable {name!r} is too terse")

if errors:
    print("S88 Python readability violations:", file=sys.stderr)
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
