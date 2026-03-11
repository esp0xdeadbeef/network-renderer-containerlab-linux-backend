from __future__ import annotations

from typing import Dict, Any, List

from clabgen.models import NodeModel, SiteModel
from clabgen.s88.Unit.common import build_node_data
from clabgen.s88.engine import render_node_s88
from clabgen.s88.CM.firewall_wan import render as render_firewall_wan


def _wan_interfaces(node: NodeModel, eth_map: Dict[str, int]) -> List[str]:
    wan_ifaces: List[str] = []
    for ifname, iface in node.interfaces.items():
        if iface.kind == "wan":
            eth = eth_map.get(ifname)
            if eth is not None:
                wan_ifaces.append(f"eth{eth}")
    return wan_ifaces


def render(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any],
) -> Dict[str, Any]:
    _ = site

    node_data = build_node_data(node_name, node, eth_map, extra=extra)

    exec_cmds: List[str] = render_node_s88(
        node_name=node_name,
        node_data=node_data,
        eth_map=eth_map,
    )

    for wan_if in _wan_interfaces(node, eth_map):
        exec_cmds.extend(render_firewall_wan(wan_if))

    return {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "exec": exec_cmds,
    }
