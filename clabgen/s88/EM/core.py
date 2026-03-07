from __future__ import annotations

from typing import Any, Dict, List

from .default import render as render_default


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> List[str]:
    return render_default(role, node_name, node_data, eth_map)
