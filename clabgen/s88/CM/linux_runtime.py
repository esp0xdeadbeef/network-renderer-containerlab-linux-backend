from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.base import render as render_cm
from clabgen.s88.CM.dns_service import render_dns_service
from clabgen.s88.CM.linux_bgp import _is_bgp_router, _render_bgp
from clabgen.s88.CM.linux_interfaces import _render_addressing, _render_interfaces
from clabgen.s88.CM.linux_routes import (
    _render_default_routes,
    _render_static_routes,
    _render_uplink_routes,
)
from clabgen.s88.CM.linux_shell import _sh
from clabgen.s88.CM.linux_wan_dynamic import render as render_dynamic_wan


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> List[str]:
    cmds: List[str] = [
        _sh('for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'),
    ]

    routing_mode = str(node_data.get("routing_mode") or "").strip().lower()
    if routing_mode not in {"static", "bgp"}:
        raise ValueError(
            f"node {node_name!r} has invalid routing_mode {routing_mode!r}"
        )

    cmds.extend(_render_interfaces(node_data, eth_map))
    cmds.extend(render_dynamic_wan(node_data, eth_map))
    cmds.extend(_render_addressing(node_data, eth_map))

    if routing_mode == "bgp" and _is_bgp_router(role):
        cmds.extend(_render_static_routes(node_data, eth_map))
        cmds.extend(_render_default_routes(node_data, eth_map))
        cmds.extend(_render_uplink_routes(node_data, eth_map))
        cmds.extend(_render_bgp(node_name, node_data, role))
    elif role != "wan-peer":
        cmds.extend(_render_static_routes(node_data, eth_map))
        cmds.extend(_render_default_routes(node_data, eth_map))

    cmds.extend(render_cm(role, node_data.get("_cm_inputs", {})))
    cmds.extend(render_dns_service(node_data))

    return cmds
