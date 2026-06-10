from __future__ import annotations

import copy
from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.CM.lab_emulation import render_lab_emulation_artifacts
from clabgen.s88.CM._wan_index import reset_wan_index
from clabgen.s88.site.bridge_networks import renderer_bridge_networks
from clabgen.s88.site.eth_map import build_eth_maps
from clabgen.s88.site.links import render_links
from clabgen.s88.site.naming import realized_bridge_name
from clabgen.s88.site.nodes import render_nodes


def _validate_pppoe_pairs(site: SiteModel) -> None:
    pairs: Dict[str, Dict[str, list[str]]] = {}

    for node_name, node in sorted(site.nodes.items()):
        services = dict(node.services or {})
        pppoe = services.get("pppoe")
        if not isinstance(pppoe, dict):
            continue

        for side in ("client", "server"):
            config = pppoe.get(side)
            if not isinstance(config, dict):
                continue

            logical = config.get("interface")
            if isinstance(logical, str) and logical:
                iface = node.interfaces.get(logical)
                bridge = iface.attach_bridge if iface is not None else None
                scope = (
                    f"bridge {bridge!r}"
                    if isinstance(bridge, str) and bridge
                    else f"interface {logical!r}"
                )
                location = f"{node_name}:{logical}"
            else:
                scope = f"node {node_name!r}"
                location = f"{node_name}:<invalid-interface>"

            bucket = pairs.setdefault(scope, {"client": [], "server": []})
            bucket[side].append(location)

    for scope, sides in sorted(pairs.items()):
        clients = sides["client"]
        servers = sides["server"]
        if len(clients) == 1 and len(servers) == 1:
            continue
        raise ValueError(
            "CLAB PPPoE pairing requires exactly one client and one server for "
            f"{scope}; got clients={clients or ['<none>']} "
            f"servers={servers or ['<none>']}"
        )


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
    reset_wan_index()
    site = copy.deepcopy(site)
    _validate_pppoe_pairs(site)
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
    lab_emulation_artifacts = render_lab_emulation_artifacts(site)

    for link in site.links.values():
        if link.bridge and link.host_uplink:
            bridge_networks.setdefault(link.bridge, dict(link.host_uplink))

    bridge_endpoint_nodes = set()
    for link in links:
        for endpoint in link.get("endpoints", []):
            if not isinstance(endpoint, str) or ":" not in endpoint:
                continue
            bridge_endpoint_nodes.add(endpoint.split(":", 1)[0])
    for bridge in bridges:
        if bridge in bridge_networks or bridge in bridge_endpoint_nodes:
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
        "lab_emulation_artifacts": lab_emulation_artifacts,
        "solver_meta": dict(site.solver_meta or {}),
    }
