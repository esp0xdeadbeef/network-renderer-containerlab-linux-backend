# ./clabgen/linux_router.py
from __future__ import annotations

from typing import Dict, Any

from .s88.engine import render_node_s88


def render_linux_router(node: Dict[str, Any], eth_map: Dict[str, int]) -> Dict[str, Any]:
    exec_cmds = render_node_s88(
        node_name=str(node.get("name", "")),
        node_data=node,
        eth_map=eth_map,
        routing_mode="static",
        disable_dynamic=True,
    )

    return {
        "exec": exec_cmds,
    }
