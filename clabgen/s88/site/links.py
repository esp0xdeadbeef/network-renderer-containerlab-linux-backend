from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.models import SiteModel
from clabgen.s88.site.naming import (
    bridge_name,
    host_ifname,
    host_uplink_interface,
    link_bridge,
)


def _prefix_sort_key(prefix: str) -> tuple[bool, str]:
    return (":" in prefix, prefix)


def _tenant_group_key(iface_name: str, node_name: str, iface: Any) -> str:
    prefixes: List[str] = []

    for addr in (iface.addr4, iface.addr6):
        if not isinstance(addr, str) or not addr:
            continue
        try:
            prefixes.append(str(ipaddress.ip_interface(addr).network))
        except ValueError:
            continue

    if prefixes:
        family_sorted = sorted(prefixes, key=_prefix_sort_key)
        return family_sorted[0]

    raise ValueError(
        f"tenant interface has no usable prefix for node={node_name!r} iface={iface_name!r}"
    )


def _link_endpoint(
    site: SiteModel,
    node_name: str,
    ep: Dict[str, Any],
    eth_maps: Dict[str, Dict[str, int]],
) -> str | None:
    if node_name not in eth_maps:
        return None
    iface = ep.get("interface")
    if iface is None or iface not in eth_maps[node_name]:
        return None
    return f"{node_name}:eth{eth_maps[node_name][iface]}"


def _macvlan_link(
    endpoint: str, bridge: str, host_uplink: Dict[str, Any]
) -> Dict[str, Any]:
    node_name, ifname = endpoint.split(":", 1)
    host_if = host_uplink_interface(host_uplink)
    if host_if is None:
        raise ValueError(f"host uplink is not renderable as macvlan: {host_uplink!r}")

    labels = {
        "clab.link.type": "macvlan",
        "clab.host.parent": str(host_uplink.get("parent") or ""),
        "clab.host.uplink": str(host_uplink.get("upstream") or ""),
        "clab.host.interface": host_if,
        "clab.link.bridge": bridge,
    }
    if isinstance(host_uplink.get("vlan"), int):
        labels["clab.host.vlan"] = str(host_uplink["vlan"])

    return {
        "endpoints": [
            f"{node_name}:{ifname}",
            f"macvlan:{host_if}",
        ],
        "labels": labels,
    }


def _render_model_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, int]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    links: List[Dict[str, Any]] = []
    bridges: List[str] = []

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        endpoints: List[str] = []
        for node_name, endpoint_data in sorted(link.endpoints.items()):
            endpoint = _link_endpoint(site, node_name, endpoint_data, eth_maps)
            if endpoint is not None:
                endpoints.append(endpoint)

        if len(endpoints) == 1:
            bridge = link_bridge(site, link, link_name)
            if host_uplink_interface(link.host_uplink):
                links.append(_macvlan_link(endpoints[0], bridge, link.host_uplink))
                continue

            bridges.append(bridge)
            endpoints.append(f"host:{host_ifname(f'{bridge}-{link_name}')}")
            links.append(_bridge_link(endpoints, bridge))
            continue

        if len(endpoints) == 2:
            bridge = link_bridge(site, link, link_name)
            bridges.append(bridge)
            links.append(_bridge_link(endpoints, bridge))

    return links, bridges


def _bridge_link(endpoints: List[str], bridge: str) -> Dict[str, Any]:
    return {
        "endpoints": endpoints,
        "labels": {
            "clab.link.type": "bridge",
            "clab.link.bridge": bridge,
        },
    }


def _tenant_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, int]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    tenant_groups: Dict[str, List[str]] = {}

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        for ifname, iface in sorted(node.interfaces.items()):
            if iface.kind != "tenant":
                continue
            eth = eth_maps[node_name].get(ifname)
            if eth is None:
                continue
            tenant_key = _tenant_group_key(ifname, node_name, iface)
            tenant_groups.setdefault(tenant_key, []).append(f"{node_name}:eth{eth}")

    links: List[Dict[str, Any]] = []
    bridges: List[str] = []
    for tenant in sorted(tenant_groups.keys()):
        bridge = bridge_name(f"{site.enterprise}-{site.site}-tenant-{tenant}")
        endpoints = list(tenant_groups[tenant])
        if len(endpoints) == 1:
            endpoints.append(f"host:{host_ifname(f'{bridge}-tenant')}")
        bridges.append(bridge)
        links.append(_bridge_link(endpoints, bridge))

    return links, bridges


def _overlay_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, int]]
) -> List[Dict[str, Any]]:
    links: List[Dict[str, Any]] = []

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        for ifname, iface in sorted(node.interfaces.items()):
            if iface.kind != "overlay":
                continue
            eth = eth_maps[node_name].get(ifname)
            if eth is None:
                continue
            links.append(
                {
                    "endpoints": [f"{node_name}:eth{eth}"],
                    "labels": {
                        "clab.link.type": "overlay",
                        "clab.overlay": iface.overlay or ifname,
                    },
                }
            )

    return links


def render_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, int]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    links, bridges = _render_model_links(site, eth_maps)
    tenant_links, tenant_bridges = _tenant_links(site, eth_maps)

    links.extend(tenant_links)
    links.extend(_overlay_links(site, eth_maps))
    bridges.extend(tenant_bridges)

    return links, sorted(set(bridges))
