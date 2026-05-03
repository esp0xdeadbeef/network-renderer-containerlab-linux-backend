from __future__ import annotations

from typing import Any, Dict
import copy

from clabgen.models import SiteModel
from clabgen.s88.site.eth_map import build_eth_maps
from clabgen.s88.site.links import render_links
from clabgen.s88.site.nodes import render_nodes


def _renderer_bridge_networks(site: SiteModel) -> Dict[str, Any]:
    deployment = site.renderer_inventory.get("deployment", {})
    if not isinstance(deployment, dict):
        return {}

    hosts = deployment.get("hosts", {})
    if not isinstance(hosts, dict):
        return {}

    bridge_networks: Dict[str, Any] = {}

    for host in hosts.values():
        if not isinstance(host, dict):
            continue

        uplinks = host.get("uplinks", {})
        if isinstance(uplinks, dict):
            for uplink in uplinks.values():
                if not isinstance(uplink, dict):
                    continue
                bridge = uplink.get("bridge")
                if isinstance(bridge, str) and bridge:
                    bridge_networks[bridge] = dict(uplink)

        bridges = host.get("bridgeNetworks", {})
        if isinstance(bridges, dict):
            for bridge_name, bridge in bridges.items():
                if not isinstance(bridge_name, str) or not bridge_name:
                    continue
                if isinstance(bridge, dict) and bridge:
                    bridge_networks.setdefault(bridge_name, dict(bridge))

    return bridge_networks


def render_site_topology(site: SiteModel) -> Dict[str, Any]:
    site = copy.deepcopy(site)
    bridge_networks = _renderer_bridge_networks(site)
    for link in site.links.values():
        if not link.bridge or not link.host_uplink:
            continue
        bridge_network = bridge_networks.get(link.bridge)
        if isinstance(bridge_network, dict):
            merged = dict(bridge_network)
            merged.update(link.host_uplink)
            link.host_uplink = merged

    eth_maps = build_eth_maps(site)
    nodes = render_nodes(site, eth_maps)
    links, bridges = render_links(site, eth_maps)

    for link in site.links.values():
        if link.bridge and link.host_uplink:
            bridge_networks.setdefault(link.bridge, dict(link.host_uplink))

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
