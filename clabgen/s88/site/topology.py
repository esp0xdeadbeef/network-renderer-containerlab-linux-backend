from __future__ import annotations

import copy
from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.site.bridge_networks import renderer_bridge_networks
from clabgen.s88.site.eth_map import build_eth_maps
from clabgen.s88.site.links import render_links
from clabgen.s88.site.naming import realized_bridge_name
from clabgen.s88.site.nodes import render_nodes


def _normalize_bridge_references(site: SiteModel) -> None:
    for link in site.links.values():
        if link.bridge:
            link.bridge = realized_bridge_name(link.bridge)
        if isinstance(link.host_uplink, dict):
            bridge = link.host_uplink.get("bridge")
            if isinstance(bridge, str) and bridge:
                link.host_uplink["bridge"] = realized_bridge_name(bridge)

    for node in site.nodes.values():
        for iface in node.interfaces.values():
            if iface.attach_bridge:
                iface.attach_bridge = realized_bridge_name(iface.attach_bridge)
            bridge = iface.host_uplink.get("bridge")
            if isinstance(bridge, str) and bridge:
                iface.host_uplink["bridge"] = realized_bridge_name(bridge)


def render_site_topology(site: SiteModel) -> Dict[str, Any]:
    site = copy.deepcopy(site)
    bridge_networks = renderer_bridge_networks(site)
    _normalize_bridge_references(site)
    site.bridge_networks = bridge_networks
    for link in site.links.values():
        if not link.bridge or not link.host_uplink:
            continue
        bridge_network = bridge_networks.get(link.bridge)
        if isinstance(bridge_network, dict):
            merged = dict(bridge_network)
            merged.update(link.host_uplink)
            link.host_uplink = merged

    for node in site.nodes.values():
        for iface in node.interfaces.values():
            if not iface.attach_bridge or not iface.host_uplink:
                continue
            bridge_network = bridge_networks.get(iface.attach_bridge)
            if isinstance(bridge_network, dict):
                merged = dict(bridge_network)
                merged.update(iface.host_uplink)
                iface.host_uplink = merged

    eth_maps = build_eth_maps(site)
    nodes = render_nodes(site, eth_maps)
    links, bridges = render_links(site, eth_maps)

    for link in site.links.values():
        if link.bridge and link.host_uplink:
            bridge_networks.setdefault(link.bridge, dict(link.host_uplink))

    for bridge in bridges:
        if bridge in bridge_networks:
            nodes.setdefault(bridge, {"kind": "bridge"})

    return {
        "name": f"{site.enterprise}-{site.site}",
        "topology": {
            "defaults": {
                "kind": "linux",
                "image": "clab-frr-plus-tooling:latest",
            },
            "nodes": nodes,
            "links": links,
        },
        "bridges": bridges,
        "bridge_networks": bridge_networks,
        "bridge_control_modules": {},
        "solver_meta": dict(site.solver_meta or {}),
    }
