# ./clabgen/s88/EM/base.py
from __future__ import annotations

from typing import Any, Dict, List

from clabgen.interfaces import render_interfaces
from clabgen.addressing import render_addressing
from clabgen.connected_routes import render_connected_routes
from clabgen.static_routes import render_static_routes
from clabgen.default_routes import render_default_routes
from clabgen.s88.CM.base import render as render_cm


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
    routing_mode: str = "static",
    disable_dynamic: bool = True,
) -> List[str]:
    _ = routing_mode
    _ = disable_dynamic

    cmds: List[str] = [
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
    ]

    cmds.extend(render_interfaces(node_data, eth_map))
    cmds.extend(render_addressing(node_data, eth_map))
    cmds.extend(render_connected_routes(node_data, eth_map))
    cmds.extend(render_static_routes(node_data, eth_map))
    cmds.extend(render_default_routes(node_data, eth_map))
    cmds.extend(render_cm(role, node_name))

    return cmds
