from __future__ import annotations

import hashlib
from typing import Dict

from clabgen.models import SiteModel

MAX_IFNAME = 15


def _short_ifname(seed: str) -> str:
    """Generate a deterministic short interface name for names exceeding IFNAMSIZ."""
    if len(seed) <= MAX_IFNAME:
        return seed
    digest = hashlib.blake2s(seed.encode(), digest_size=6).hexdigest()
    return f"if-{digest}"[:MAX_IFNAME]


def _target_ifname(site: SiteModel, node_name: str, logical_ifname: str) -> str:
    node = site.nodes.get(node_name)
    if node is None:
        raise ValueError(f"link endpoint references unknown node {node_name!r}")
    iface = node.interfaces.get(logical_ifname)
    if iface is None:
        raise ValueError(
            f"link endpoint references missing interface {node_name!r}.{logical_ifname!r}"
        )
    target_ifname = iface.runtime_if_name
    if not isinstance(target_ifname, str) or not target_ifname:
        raise ValueError(
            f"interface {node_name!r}.{logical_ifname!r} missing CPM runtimeIfName"
        )
    return _short_ifname(target_ifname)


def _add_mapping(
    eth_maps: Dict[str, Dict[str, str]],
    used_names: Dict[str, Dict[str, str]],
    site: SiteModel,
    node_name: str,
    logical_ifname: str,
) -> None:
    target_ifname = _target_ifname(site, node_name, logical_ifname)
    current_logical = used_names[node_name].get(target_ifname)
    if current_logical is not None and current_logical != logical_ifname:
        raise ValueError(
            f"node {node_name!r} maps both {current_logical!r} and "
            f"{logical_ifname!r} to runtimeIfName {target_ifname!r}"
        )
    eth_maps[node_name][logical_ifname] = target_ifname
    used_names[node_name][target_ifname] = logical_ifname


def build_eth_maps(site: SiteModel) -> Dict[str, Dict[str, str]]:
    eth_maps: Dict[str, Dict[str, str]] = {}
    used_names: Dict[str, Dict[str, str]] = {}
    for node_name in site.nodes:
        eth_maps[node_name] = {}
        used_names[node_name] = {}

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        for node_name, ep in sorted(link.endpoints.items()):
            if node_name not in site.nodes:
                raise ValueError(f"link endpoint references unknown node {node_name!r}")
            iface = ep.get("interface")
            if not isinstance(iface, str) or not iface:
                raise ValueError(
                    f"link endpoint for node {node_name!r} is missing explicit interface"
                )
            if iface not in eth_maps[node_name]:
                _add_mapping(eth_maps, used_names, site, node_name, iface)

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        for ifname in sorted(node.interfaces.keys()):
            iface = node.interfaces[ifname]
            if (
                iface.kind in {"tenant", "overlay"}
                and ifname not in eth_maps[node_name]
            ):
                _add_mapping(eth_maps, used_names, site, node_name, ifname)

    return eth_maps
