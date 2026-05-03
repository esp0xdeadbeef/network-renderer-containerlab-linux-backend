from __future__ import annotations

import copy
from typing import Dict, Any, List

from clabgen.models import NodeModel
from clabgen.s88.EM.base import render as render_em


def _routing_mode(node: NodeModel) -> str:
    value = getattr(node, "routing_mode", None)
    if not isinstance(value, str) or not value:
        raise ValueError(f"node {node.name!r} missing explicit routing_mode")
    value = value.strip().lower()
    if value not in {"static", "bgp"}:
        raise ValueError(f"node {node.name!r} has invalid routing_mode {value!r}")
    return value


def build_node_data(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode(node)

    node_data: Dict[str, Any] = {
        "name": node_name,
        "role": node.role,
        "routing_mode": routing_mode,
        "interfaces": {},
        "route_intents": list(node.route_intents),
        "services": copy.deepcopy(node.services),
        "loopback": {
            "ipv4": node.loopback4,
            "ipv6": node.loopback6,
        },
    }

    interfaces: Dict[str, Any] = {}
    for ifname, iface in sorted(node.interfaces.items()):
        if ifname not in eth_map:
            continue
        interfaces[ifname] = {
            "addr4": iface.addr4,
            "addr6": iface.addr6,
            "ll6": iface.ll6,
            "kind": iface.kind,
            "tenant": iface.tenant,
            "overlay": iface.overlay,
            "upstream": iface.upstream,
            "routes": iface.routes,
        }
    node_data["interfaces"] = interfaces

    if extra:
        node_data.update(copy.deepcopy(extra))

    return node_data


def render_linux_node(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode(node)
    node_data = build_node_data(node_name, node, eth_map, extra=extra)

    exec_cmds = render_em(
        node.role,
        node_name,
        node_data,
        eth_map,
        routing_mode=routing_mode,
        disable_dynamic=(routing_mode != "bgp"),
    )

    return {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "exec": exec_cmds,
    }
