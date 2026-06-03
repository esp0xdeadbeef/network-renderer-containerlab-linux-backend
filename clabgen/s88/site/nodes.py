from __future__ import annotations

from typing import Any, Dict
import ipaddress

from clabgen.models import NodeModel, SiteModel
from clabgen.s88.site.node_runtime import render_linux_node


def _loopback_ip(value: str | None) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(ipaddress.ip_interface(value).ip)
    except ValueError:
        return None


def _node_extra(site: SiteModel, node_name: str) -> Dict[str, Any]:
    node = site.nodes[node_name]
    bgp = getattr(node, "bgp", {}) or {}
    if not isinstance(bgp, dict):
        bgp = {}

    renderer_inventory = getattr(site, "renderer_inventory", {}) or {}
    if not isinstance(renderer_inventory, dict):
        renderer_inventory = {}

    containerlab = renderer_inventory.get("containerlab", {})
    if not isinstance(containerlab, dict):
        containerlab = {}

    return {
        "loopback": {
            "ipv4": node.loopback4,
            "ipv6": node.loopback6,
        },
        "bgp": bgp,
        "containerlab": containerlab,
        "upstreamEmulation": getattr(site, "upstream_emulation", {}) or {},
    }


def render_nodes(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
) -> Dict[str, Any]:
    nodes: Dict[str, Any] = {}

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        role = str(node.role or "").strip()
        if role not in {
            "access",
            "client",
            "core",
            "downstream-selector",
            "policy",
            "upstream-selector",
            "wan-peer",
        }:
            raise ValueError(f"No Unit renderer for role={role!r} node={node_name!r}")

        extra = _node_extra(site, node_name)

        nodes[node_name] = render_linux_node(
            node_name=node_name,
            node=node,
            eth_map=eth_maps.get(node_name, {}),
            extra=extra,
        )

    for row in sorted((getattr(site, "upstream_emulation", {}) or {}).values(), key=lambda item: str(item.get("scenarioId") or "")):
        if not isinstance(row, dict) or row.get("mode") != "pppoe":
            continue
        server = (row.get("pppoe") or {}).get("server") or {}
        node_name = server.get("node")
        if not isinstance(node_name, str) or not node_name or node_name in nodes:
            continue
        node_data = {
            "name": node_name,
            "role": "pppoe-access-concentrator",
            "routing_mode": "static",
            "interfaces": {},
            "route_intents": [],
            "services": {},
            "egressIntent": {},
            "natIntent": {},
            "forwardingIntent": {},
            "loopback": {"ipv4": None, "ipv6": None},
            "upstreamEmulation": {node_name: row},
        }
        exec_cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            "ip link set lo up",
        ]
        from clabgen.s88.CM.pppoe_runtime import render as render_pppoe_runtime

        exec_cmds.extend(render_pppoe_runtime(node_name, node_data, {}))
        nodes[node_name] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
            "network-mode": "none",
            "restart-policy": "no",
            "cmd": "/bin/sh -c 'sleep infinity'",
            "exec": exec_cmds,
        }

    return nodes
