from __future__ import annotations

from typing import Dict, Any, List


def render(role: str, node_name: str, node_data: Dict[str, Any]) -> List[str]:
    _ = node_name
    _ = node_data

    if role != "upstream-selector":
        return []

    return []
