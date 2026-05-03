from __future__ import annotations

from typing import Dict

from clabgen.models import SiteModel


def build_eth_maps(site: SiteModel) -> Dict[str, Dict[str, int]]:
    eth_maps: Dict[str, Dict[str, int]] = {}
    counters: Dict[str, int] = {}
    for node_name in site.nodes:
        eth_maps[node_name] = {}
        counters[node_name] = 1

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        for node_name, ep in sorted(link.endpoints.items()):
            if node_name not in site.nodes:
                continue
            iface = ep.get("interface")
            if iface is None:
                continue
            if iface not in eth_maps[node_name]:
                eth_maps[node_name][iface] = counters[node_name]
                counters[node_name] += 1

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        for ifname in sorted(node.interfaces.keys()):
            iface = node.interfaces[ifname]
            if (
                iface.kind in {"tenant", "overlay"}
                and ifname not in eth_maps[node_name]
            ):
                eth_maps[node_name][ifname] = counters[node_name]
                counters[node_name] += 1

    return eth_maps
