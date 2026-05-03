from __future__ import annotations


def _sh(cmd: str) -> str:
    escaped = cmd.replace("'", "'\"'\"'")
    return f"sh -c '{escaped}'"
