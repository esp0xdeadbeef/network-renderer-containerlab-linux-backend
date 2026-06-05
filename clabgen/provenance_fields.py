from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

from clabgen.solver_json import parse_json_candidates


_SECRET_KEY_PARTS = (
    "password",
    "passphrase",
    "private",
    "secret",
    "token",
)


def load_json_object(path: Path) -> Dict[str, Any]:
    try:
        return parse_json_candidates(path, path.read_text())
    except Exception:
        return {}


def safe_value(value: Any) -> Any:
    if isinstance(value, dict):
        result: Dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if any(part in key_text.lower() for part in _SECRET_KEY_PARTS):
                result[key_text] = "<redacted>"
            else:
                result[key_text] = safe_value(item)
        return result
    if isinstance(value, list):
        return [safe_value(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def first_dict(*values: Any) -> Dict[str, Any]:
    for value in values:
        if isinstance(value, dict):
            return value
    return {}


def source_classes(meta: Dict[str, Any]) -> Dict[str, Any]:
    explicit = meta.get("sourceClasses")
    if isinstance(explicit, dict):
        return safe_value(explicit)

    result: Dict[str, Any] = {}
    aliases = {
        "userIntent": ("userIntent", "userIntentSource", "intent", "intentSource"),
        "publicInventory": (
            "publicInventory",
            "publicInventorySource",
            "inventory",
            "inventorySource",
        ),
        "protectedInventory": (
            "protectedInventory",
            "protectedInventorySource",
        ),
        "runtimeFacts": ("runtimeFacts", "runtimeFactSet", "runtimeFactSource"),
        "validationContext": (
            "validationContext",
            "validationContextFacts",
            "validationContextSource",
        ),
    }
    for source_class, keys in aliases.items():
        for key in keys:
            value = meta.get(key)
            if value is not None:
                result[source_class] = safe_value(value)
                break
    return result


def upstream_locks(meta: Dict[str, Any]) -> Dict[str, Any]:
    locks = first_dict(
        meta.get("locks"),
        meta.get("lock"),
        meta.get("lockedToolChain"),
        meta.get("toolChainLocks"),
        meta.get("flakeLocks"),
    )
    return safe_value(locks)


def renderer_lock_summary(repo_root: Path) -> Dict[str, Any]:
    lock_path = repo_root / "flake.lock"
    try:
        lock = json.loads(lock_path.read_text())
    except Exception:
        return {"available": False}

    nodes = lock.get("nodes")
    if not isinstance(nodes, dict):
        return {"available": False}

    summary: Dict[str, Any] = {}
    for name, node in sorted(nodes.items()):
        if not isinstance(name, str) or not isinstance(node, dict):
            continue
        locked = node.get("locked")
        if not isinstance(locked, dict):
            continue
        item = {
            key: locked[key]
            for key in ("type", "owner", "repo", "rev", "narHash", "lastModified")
            if key in locked
        }
        if item:
            summary[name] = item

    return {"available": True, "nodes": summary}
