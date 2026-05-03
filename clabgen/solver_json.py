from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict


def _strip_hash_comment_lines(text: str) -> str:
    lines = text.splitlines()
    while lines and lines[0].lstrip().startswith("#"):
        lines.pop(0)
    return "\n".join(lines).strip()


def _dump_parse_failure(path: Path, raw: str, errors: list[str]) -> None:
    header = f"[clabgen.solver] failed to parse solver input: {path}"
    divider = "-" * len(header)

    print(divider, file=sys.stderr)
    print(header, file=sys.stderr)
    print(divider, file=sys.stderr)

    for error in errors:
        print(error, file=sys.stderr)

    print("[clabgen.solver] raw input follows:", file=sys.stderr)
    print(raw, file=sys.stderr)
    print(divider, file=sys.stderr)


def parse_json_candidates(path: Path, raw: str) -> Dict[str, Any]:
    candidates = [
        ("raw", raw),
        ("without-leading-hash-comments", _strip_hash_comment_lines(raw)),
    ]

    errors: list[str] = []

    for name, candidate in candidates:
        if not candidate:
            continue
        try:
            data = json.loads(candidate)
        except Exception as exc:
            errors.append(f"[candidate:{name}] {type(exc).__name__}: {exc}")
            continue

        if not isinstance(data, dict):
            raise ValueError("solver JSON top-level must be an object")

        return data

    _dump_parse_failure(path, raw, errors)

    if errors:
        raise ValueError(
            "unable to parse solver input as JSON; raw input dumped to stderr"
        )

    raise ValueError("solver input is empty")
