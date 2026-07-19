from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.base import render as render_cm
from clabgen.s88.CM.dns_service import render_dns_resolver_config, render_dns_service
from clabgen.s88.CM.linux_bgp import _is_bgp_router, _render_bgp
from clabgen.s88.CM.linux_interfaces import _render_addressing, _render_interfaces
from clabgen.s88.CM.linux_routes import (
    _render_default_routes,
    _render_static_routes,
)
from clabgen.s88.CM.fs370_forwarding_validation import (
    validate_fs370_forwarding_commands,
)
from clabgen.s88.CM.linux_policy_routes import render as render_policy_routes
from clabgen.s88.CM.linux_uplink_routes import _render_uplink_routes
from clabgen.s88.CM.linux_shell import _sh
from clabgen.s88.CM.access_advertisements import render as render_access_advertisements
from clabgen.s88.CM.linux_wan_dynamic import render as render_dynamic_wan
from clabgen.s88.CM.pppoe_runtime import render as render_pppoe_runtime


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> List[str]:
    cmds: List[str] = [
        _sh('for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'),
    ]

    raw_routing_mode = node_data.get("routing_mode")
    routing_mode = (
        raw_routing_mode.strip().lower() if isinstance(raw_routing_mode, str) else ""
    )
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
        cmds.extend(render_policy_routes(node_data, eth_map))
        cmds.extend(_render_uplink_routes(node_data, eth_map))
        cmds.extend(_render_bgp(node_name, node_data, role))
    elif role != "wan-peer":
        cmds.extend(_render_static_routes(node_data, eth_map))
        cmds.extend(_render_default_routes(node_data, eth_map))
        cmds.extend(render_policy_routes(node_data, eth_map))

    cmds.extend(render_cm(node_data.get("_cm_inputs", {})))
    cmds.extend(render_dns_resolver_config(node_data, node_name))
    cmds.extend(render_access_advertisements(node_data, eth_map))
    cmds.extend(render_dns_service(node_data, node_name))
    cmds.extend(render_pppoe_runtime(node_name, node_data, eth_map))

    validate_fs370_forwarding_commands(node_data, eth_map, cmds)

    return cmds
