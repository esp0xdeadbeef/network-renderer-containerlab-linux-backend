from __future__ import annotations

from typing import Dict
import hashlib

from .models import SiteModel


def build_eth_index(site: SiteModel) -> Dict[str, Dict[str, int]]:
    eth_index: Dict[str, Dict[str, int]] = {}

    for unit in site.nodes.keys():
        eth_index[unit] = {}

    # Reserve eth0 for containerlab management NIC.
    # Dataplane interfaces start at eth1.
    counters: Dict[str, int] = {u: 1 for u in site.nodes.keys()}

    # First allocate deterministic eth indexes for real topology links.
    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        for unit in sorted(link.endpoints.keys()):
            if unit not in eth_index:
                continue
            eth_index[unit][link_name] = counters[unit]
            counters[unit] += 1

    # Then allocate deterministic eth indexes for node-local logical/virtual
    # interfaces that are not backed by a projected site link. This renders
    # access tenant networks as dataplane interfaces (for example eth2).
    for unit in sorted(site.nodes.keys()):
        node = site.nodes[unit]

        for ifname in sorted(node.interfaces.keys()):
            if ifname in eth_index[unit]:
                continue

            iface = node.interfaces[ifname]
            if (
                getattr(iface, "kind", None) == "tenant"
                or getattr(iface, "upstream", None) == "tenant"
            ):
                eth_index[unit][ifname] = counters[unit]
                counters[unit] += 1

    return eth_index


def short_bridge(name: str) -> str:
    # linux bridge name limit is 15 chars
    # enforce deterministic 15-char max: "br-" + 12 hex chars = 15
    h = hashlib.sha1(name.encode()).hexdigest()[:12]
    return f"br-{h}"
