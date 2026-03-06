# ./clabgen/s88/engine.py
from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.EM.base import render as render_em


def render_node_s88(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
    routing_mode: str = "static",
    disable_dynamic: bool = True,
) -> List[str]:
    role = str(node_data.get("role", "") or "default")

    return render_em(
        role=role,
        node_name=node_name,
        node_data=node_data,
        eth_map=eth_map,
        routing_mode=routing_mode,
        disable_dynamic=disable_dynamic,
    )
