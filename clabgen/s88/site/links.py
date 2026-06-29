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


def _pppoe_service_endpoints(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
) -> Dict[str, Dict[str, List[str]]]:
    pairs: Dict[str, Dict[str, List[str]]] = {}

    for node_name, node in sorted(site.nodes.items()):
        pppoe = (node.services or {}).get("pppoe")
        if not isinstance(pppoe, dict):
            continue
        for side in ("client", "server"):
            service = pppoe.get(side)
            if not isinstance(service, dict):
                continue
            logical = service.get("interface")
            if not isinstance(logical, str) or not logical:
                continue
            iface = node.interfaces.get(logical)
            if iface is None or not iface.attach_bridge:
                continue
            runtime_if = eth_maps.get(node_name, {}).get(logical)
            if runtime_if is None:
                continue
            bridge = iface.attach_bridge
            bucket = pairs.setdefault(bridge, {"client": [], "server": []})
            bucket[side].append(f"{node_name}:{runtime_if}")

    return pairs


def _pppoe_handoff_links(
    site: SiteModel,
    eth_maps: Dict[str, Dict[str, str]],
    existing_links: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    existing_endpoint_sets = {
        frozenset(link.get("endpoints", []))
        for link in existing_links
        if isinstance(link.get("endpoints"), list)
    }
    links: List[Dict[str, Any]] = []

    for bridge, sides in sorted(_pppoe_service_endpoints(site, eth_maps).items()):
        clients = sides["client"]
        servers = sides["server"]
        if len(clients) != 1 or len(servers) != 1:
            continue
        endpoints = [clients[0], servers[0]]
        if frozenset(endpoints) in existing_endpoint_sets:
            continue
        links.append(_bridge_link(endpoints, bridge, f"pppoe-handoff-{bridge}"))

    return links


def render_links(
    site: SiteModel, eth_maps: Dict[str, Dict[str, str]]
) -> tuple[List[Dict[str, Any]], List[str]]:
    links, bridges = _render_model_links(site, eth_maps)
    tenant_links, tenant_bridges = render_tenant_links(site, eth_maps)

    links.extend(tenant_links)
    links.extend(_overlay_links(site, eth_maps))
    pppoe_links = _pppoe_handoff_links(site, eth_maps, links)
    links.extend(pppoe_links)
    bridges.extend(tenant_bridges)
    bridges.extend(
        link["labels"]["clab.link.bridge"]
        for link in pppoe_links
        if isinstance(link.get("labels"), dict)
        and isinstance(link["labels"].get("clab.link.bridge"), str)
    )

    return links, sorted(set(bridges))
