from __future__ import annotations

from typing import Any, Dict, List


def require_runtime_name(value: Any, name_map: Dict[str, str], context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} is missing explicit interface name")
    translated = name_map.get(value)
    if not isinstance(translated, str) or not translated:
        # Allow PPPoE session interfaces to pass through unchanged
        if value.startswith("ppp"):
            return value
        import sys
        print(f"DIAGNOSTIC: require_runtime_name failed for {value!r} in {context}", file=sys.stderr)
        print(f"DIAGNOSTIC: name_map keys (partial): {list(name_map.keys())[:20]}", file=sys.stderr)
        raise ValueError(
            f"{context} references interface {value!r} without explicit CPM runtimeIfName"
        )
    return translated


def translate_names(
    values: List[str], name_map: Dict[str, str], context: str
) -> List[str]:
    translated_names: List[str] = []
    for value in values:
        translated_names.append(require_runtime_name(value, name_map, context))
    return translated_names
