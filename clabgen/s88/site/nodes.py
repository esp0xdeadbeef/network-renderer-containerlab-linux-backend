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

    return nodes
