from __future__ import annotations

from typing import List
import hashlib

from clabgen.models import SiteModel

MAX_NODE_NAME = 64


def _hash5(value: str) -> str:
    return hashlib.blake2s(value.encode(), digest_size=3).hexdigest()[:5]


def _tail_tokens(value: str, max_len: int) -> str:
    if max_len <= 0:
        return ""
    if len(value) <= max_len:
        return value

    parts: List[str] = []
    for part in value.split("-"):
        if part:
            parts.append(part)
    if not parts:
        return value[-max_len:]

    selected: List[str] = []
    total = 0
    for part in reversed(parts):
        extra = len(part) + (1 if selected else 0)
        if total + extra > max_len:
            break
        selected.append(part)
        total += extra

    if selected:
        return "-".join(reversed(selected))
    return value[-max_len:]


def scoped_node_name(site: SiteModel, node_name: str) -> str:
    enterprise = site.enterprise
    site_name = site.site
    candidates = [
        f"{enterprise}-{site_name}-{node_name}",
        f"{_hash5(enterprise)}-{site_name}-{node_name}",
        f"{_hash5(enterprise)}-{_hash5(site_name)}-{node_name}",
    ]

    for candidate in candidates:
        if len(candidate) <= MAX_NODE_NAME:
            return candidate

    prefix = f"{_hash5(enterprise)}-{_hash5(site_name)}-"
    remaining = MAX_NODE_NAME - len(prefix)
    if remaining <= 0:
        return prefix[:MAX_NODE_NAME]

    return f"{prefix}{_tail_tokens(node_name, remaining)}"[:MAX_NODE_NAME]
