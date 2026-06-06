from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
from typing import Any, Dict

from clabgen.solver_json import parse_json_candidates


_SECRET_KEY_PARTS = ("password", "passphrase", "private", "secret", "token")


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


def _env_value(name: str) -> str | None:
    value = os.environ.get(name, "").strip()
    return value or None


def _git_rev(repo_root: Path) -> str | None:
    try:
        return (
            subprocess.check_output(
                ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
    except Exception:
        return None


def _git_dirty(repo_root: Path) -> bool | None:
    try:
        subprocess.check_call(
            ["git", "-C", str(repo_root), "diff", "--quiet"],
            stderr=subprocess.DEVNULL,
        )
        subprocess.check_call(
            ["git", "-C", str(repo_root), "diff", "--cached", "--quiet"],
            stderr=subprocess.DEVNULL,
        )
        return False
    except subprocess.CalledProcessError:
        return True
    except Exception:
        return None


def renderer_source_identity(repo_root: Path) -> Dict[str, Any]:
    env_rev = _env_value("CLAB_RENDERER_SOURCE_REV")
    git_rev = _git_rev(repo_root)
    rev = env_rev or git_rev or "unknown"
    short_rev = _env_value("CLAB_RENDERER_SOURCE_SHORT_REV") or (
        rev[:7] if rev != "unknown" else "unknown"
    )
    dirty_env = _env_value("CLAB_RENDERER_SOURCE_DIRTY")
    git_dirty = _git_dirty(repo_root)
    if dirty_env in {"0", "false", "False"}:
        dirty: bool | str = False
    elif dirty_env in {"1", "true", "True"}:
        dirty = True
    elif git_dirty is not None:
        dirty = git_dirty
    else:
        dirty = "unknown"

    name = _env_value("CLAB_RENDERER_SOURCE_NAME") or repo_root.name
    identity = f"{name}@{short_rev}"
    rev_source = "env" if env_rev else ("git" if git_rev else "unknown")
    nar_hash = _env_value("CLAB_RENDERER_SOURCE_NAR_HASH")
    immutable_from_git = rev != "unknown" and dirty is False
    immutable_from_nar = nar_hash is not None
    result: Dict[str, Any] = {
        "name": name,
        "identity": identity,
        "rev": rev,
        "shortRev": short_rev,
        "dirty": dirty,
        "revSource": rev_source,
        "outPath": _env_value("CLAB_RENDERER_SOURCE_OUT_PATH") or str(repo_root),
        "immutable": immutable_from_git or immutable_from_nar,
        "immutableProof": (
            "git-rev"
            if immutable_from_git
            else ("narHash" if immutable_from_nar else "none")
        ),
    }
    last_modified = _env_value("CLAB_RENDERER_SOURCE_LAST_MODIFIED")
    if last_modified is not None:
        result["lastModified"] = last_modified
    if nar_hash is not None:
        result["narHash"] = nar_hash
    return result


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
