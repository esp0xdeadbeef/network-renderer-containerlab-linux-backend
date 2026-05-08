from __future__ import annotations

import ipaddress
from typing import Any, Dict, List

from clabgen.models import SiteModel
from clabgen.s88.site.naming import bridge_name, host_ifname, host_uplink_interface


def _prefix_sort_key(prefix: str) -> tuple[bool, str]:
    return (":" in prefix, prefix)


def _tenant_group_key(iface_name: str, node_name: str, iface: Any) -> str:
    attached_bridge = getattr(iface, "attach_bridge", None)
    if isinstance(attached_bridge, str) and attached_bridge:
        return attached_bridge

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


def _bridge_link(endpoints: List[str], bridge: str) -> Dict[str, Any]:
    return {
        "endpoints": endpoints,
        "labels": {
            "clab.link.type": "bridge",
            "clab.link.bridge": bridge,
        },
    }


def _host_bridge_link(
    endpoint: str, bridge: str, tenant_key: str, host_uplink: Dict[str, Any]
) -> Dict[str, Any]:
    link = _bridge_link(
        [
            endpoint,
            f"{bridge}:{host_ifname(f'{bridge}-{tenant_key}-{endpoint}')}",
        ],
        bridge,
    )
    labels = link["labels"]
    labels["clab.host.parent"] = str(host_uplink.get("parent") or "")
    labels["clab.host.uplink"] = str(host_uplink.get("upstream") or "")
    labels["clab.host.interface"] = host_uplink_interface(host_uplink) or ""
    if isinstance(host_uplink.get("vlan"), int):
        labels["clab.host.vlan"] = str(host_uplink["vlan"])
    return link


def _bridge_host_uplink(site: SiteModel, bridge: str) -> Dict[str, Any]:
    bridge_data = site.bridge_networks.get(bridge)
    return dict(bridge_data) if isinstance(bridge_data, dict) else {}


def render_tenant_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, int]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    tenant_groups: Dict[str, List[str]] = {}
    tenant_bridges: Dict[str, str] = {}

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
            attached_bridge = getattr(iface, "attach_bridge", None)
            if isinstance(attached_bridge, str) and attached_bridge:
                tenant_bridges[tenant_key] = attached_bridge

    links: List[Dict[str, Any]] = []
    bridges: List[str] = []
    for tenant in sorted(tenant_groups.keys()):
        bridge = tenant_bridges.get(tenant) or bridge_name(
            f"{site.enterprise}-{site.site}-tenant-{tenant}"
        )
        endpoints = list(tenant_groups[tenant])
        host_uplink = _bridge_host_uplink(site, bridge)
        if len(endpoints) == 1 and host_uplink_interface(host_uplink):
            bridges.append(bridge)
            links.append(_host_bridge_link(endpoints[0], bridge, tenant, host_uplink))
            continue
        if len(endpoints) == 1:
            endpoints.append(f"host:{host_ifname(f'{bridge}-tenant')}")
        bridges.append(bridge)
        links.append(_bridge_link(endpoints, bridge))

    return links, bridges
