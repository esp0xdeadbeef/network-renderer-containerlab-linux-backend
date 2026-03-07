# ./clabgen/connected_routes.py
from __future__ import annotations

from typing import Dict, Any, List


def render_connected_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    _ = node
    _ = eth_map

    # Connected routes are installed automatically by the kernel when
    # addresses are assigned to interfaces. Do not emit redundant route
    # commands for them.
    return []
