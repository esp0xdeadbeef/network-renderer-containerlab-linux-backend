from __future__ import annotations

from typing import Dict, Any

import copy

from clabgen.models import NodeModel
from clabgen.s88.engine import render_node_s88


def build_node_data(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    node_data: Dict[str, Any] = {
        "name": node_name,
        "role": node.role,
        "interfaces": {
            ifname: {
                "addr4": iface.addr4,
                "addr6": iface.addr6,
                "ll6": iface.ll6,
                "kind": iface.kind,
                "tenant": iface.tenant,
                "upstream": iface.upstream,
                "routes": copy.deepcopy(iface.routes),
            }
            for ifname, iface in sorted(node.interfaces.items())
            if ifname in eth_map
        },
        "route_intents": list(node.route_intents),
    }

    if extra:
        node_data.update(copy.deepcopy(extra))

    return node_data


def render_linux_node(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    node_data = build_node_data(node_name, node, eth_map, extra=extra)
    exec_cmds = render_node_s88(node_name, node_data, eth_map)

    return {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "exec": exec_cmds,
    }
