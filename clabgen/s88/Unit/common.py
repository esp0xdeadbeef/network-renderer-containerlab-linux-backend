from __future__ import annotations

from typing import Dict, Any
import os
import copy

from clabgen.models import NodeModel
from clabgen.s88.engine import render_node_s88


_ROUTER_ROLES = {"access", "core", "policy", "upstream-selector", "wan-peer", "isp"}


def _routing_mode() -> str:
    value = os.environ.get("CLABGEN_ROUTING_MODE", "static").strip().lower()
    if value not in {"static", "bgp"}:
        return "static"
    print("Selected routing mode:", value)
    return value


def _keep_static_routes(role: str, routing_mode: str) -> bool:
    if routing_mode != "bgp":
        return True
    return role not in _ROUTER_ROLES


def build_node_data(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode()
    keep_static = _keep_static_routes(node.role, routing_mode)

    node_data: Dict[str, Any] = {
        "name": node_name,
        "role": node.role,
        "routing_mode": routing_mode,
        "interfaces": {
            ifname: {
                "addr4": iface.addr4,
                "addr6": iface.addr6,
                "ll6": iface.ll6,
                "kind": iface.kind,
                "tenant": iface.tenant,
                "overlay": iface.overlay,
                "upstream": iface.upstream,
                "routes": copy.deepcopy(iface.routes) if keep_static else {"ipv4": [], "ipv6": []},
            }
            for ifname, iface in sorted(node.interfaces.items())
            if ifname in eth_map
        },
        "route_intents": list(node.route_intents) if keep_static else [],
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
    routing_mode = _routing_mode()
    node_data = build_node_data(node_name, node, eth_map, extra=extra)

    exec_cmds = render_node_s88(
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
