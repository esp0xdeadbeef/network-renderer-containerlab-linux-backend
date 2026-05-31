from __future__ import annotations

from typing import Any, Dict, List

from clabgen.models import SiteModel
from clabgen.s88.site.naming import (
    bridge_name,
    host_ifname,
    host_uplink_interface,
    link_bridge,
)
from clabgen.s88.site.tenant_links import render_tenant_links


def _link_endpoint(
    site: SiteModel,
    node_name: str,
    ep: Dict[str, Any],
    eth_maps: Dict[str, Dict[str, str]],
) -> str | None:
    if node_name not in eth_maps:
        raise ValueError(
            f"link endpoint references node {node_name!r} outside the rendered CPM node set"
        )
    iface = ep.get("interface")
    if not isinstance(iface, str) or not iface:
        raise ValueError(
            f"link endpoint for node {node_name!r} is missing explicit interface"
        )
    if iface not in eth_maps[node_name]:
        raise ValueError(
            f"link endpoint for node {node_name!r} references interface {iface!r} "
            "without explicit CPM runtimeIfName"
        )
    return f"{node_name}:{eth_maps[node_name][iface]}"


def _host_bridge_link(
    endpoint: str, bridge: str, link_name: str, host_uplink: Dict[str, Any]
) -> Dict[str, Any]:
    link = _bridge_link(
        [
            endpoint,
            f"{bridge}:{host_ifname(f'{bridge}-{link_name}-{endpoint}')}",
        ],
        bridge,
        link_name,
    )
    labels = link["labels"]
    labels["clab.host.parent"] = str(host_uplink.get("parent") or "")
    labels["clab.host.uplink"] = str(host_uplink.get("upstream") or "")
    labels["clab.host.interface"] = host_uplink_interface(host_uplink) or ""
    if isinstance(host_uplink.get("vlan"), int):
        labels["clab.host.vlan"] = str(host_uplink["vlan"])
    return link


def _render_model_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
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
                bridges.append(bridge)
                links.append(
                    _host_bridge_link(endpoints[0], bridge, link_name, link.host_uplink)
                )
                continue

            bridges.append(bridge)
            endpoints.append(f"host:{host_ifname(f'{bridge}-{link_name}')}")
            links.append(_bridge_link(endpoints, bridge, link_name))
            continue

        if len(endpoints) == 2:
            bridge = link_bridge(site, link, link_name)
            bridges.append(bridge)
            links.append(_bridge_link(endpoints, bridge, link_name))

    return links, bridges


def _bridge_link(
    endpoints: List[str], bridge: str, source_link: str | None = None
) -> Dict[str, Any]:
    labels = {
        "clab.link.type": "bridge",
        "clab.link.bridge": bridge,
    }
    if isinstance(source_link, str) and source_link:
        labels["clab.source.link"] = source_link
    return {
        "endpoints": endpoints,
        "labels": labels,
    }


def _overlay_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
) -> List[Dict[str, Any]]:
    links: List[Dict[str, Any]] = []

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        for ifname, iface in sorted(node.interfaces.items()):
            if iface.kind != "overlay":
                continue
            target_ifname = eth_maps[node_name].get(ifname)
            if target_ifname is None:
                continue
            links.append(
                {
                    "endpoints": [f"{node_name}:{target_ifname}"],
                    "labels": {
                        "clab.link.type": "overlay",
                        "clab.overlay": iface.overlay or ifname,
                    },
                }
            )

    return links


def render_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    links, bridges = _render_model_links(site, eth_maps)
    tenant_links, tenant_bridges = render_tenant_links(site, eth_maps)

    links.extend(tenant_links)
    links.extend(_overlay_links(site, eth_maps))
    bridges.extend(tenant_bridges)

    return links, sorted(set(bridges))
