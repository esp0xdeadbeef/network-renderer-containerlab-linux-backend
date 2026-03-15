from __future__ import annotations

from typing import Dict, List, Tuple, Any, Callable
import hashlib
import ipaddress

from clabgen.models import SiteModel, NodeModel
from clabgen.s88.Unit.access import render as render_access
from clabgen.s88.Unit.client import render as render_client
from clabgen.s88.Unit.core import render as render_core
from clabgen.s88.Unit.policy import render as render_policy
from clabgen.s88.Unit.upstream_selector import render as render_upstream_selector
from clabgen.s88.Unit.wan_peer import render as render_wan_peer


NodeRenderer = Callable[[SiteModel, str, NodeModel, Dict[str, int], Dict[str, Any]], Dict[str, Any]]

MAX_BRIDGE_NAME = 15


def _bridge_name(seed: str) -> str:
    h = hashlib.blake2s(seed.encode(), digest_size=6).hexdigest()
    name = f"br-{h}"
    return name[:MAX_BRIDGE_NAME]


def _host_ifname(bridge: str) -> str:
    h = hashlib.blake2s(bridge.encode(), digest_size=2).hexdigest()
    name = f"veth-{bridge[:6]}-{h}"
    return name[:MAX_BRIDGE_NAME]


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
        family_sorted = sorted(prefixes, key=lambda p: (":" in p, p))
        return family_sorted[0]

    raise ValueError(
        f"tenant interface has no usable prefix for node={node_name!r} iface={iface_name!r}"
    )


def _build_eth_maps(site: SiteModel) -> Dict[str, Dict[str, int]]:
    eth_maps: Dict[str, Dict[str, int]] = {n: {} for n in site.nodes}
    counters: Dict[str, int] = {n: 1 for n in site.nodes}

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
            if iface.kind == "tenant" and ifname not in eth_maps[node_name]:
                eth_maps[node_name][ifname] = counters[node_name]
                counters[node_name] += 1

    return eth_maps


def _renderers() -> Dict[str, NodeRenderer]:
    return {
        "access": render_access,
        "client": render_client,
        "core": render_core,
        "policy": render_policy,
        "upstream-selector": render_upstream_selector,
        "wan-peer": render_wan_peer,
    }


def _loopback_ip(value: str | None) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(ipaddress.ip_interface(value).ip)
    except ValueError:
        return None


def _node_extra(site: SiteModel, node_name: str) -> Dict[str, Any]:
    node = site.nodes[node_name]
    neighbors: List[Dict[str, Any]] = []

    for session in site.bgp_sessions:
        a = session.get("a")
        b = session.get("b")
        rr = session.get("rr")

        if node_name not in {a, b}:
            continue

        peer_name = b if node_name == a else a
        if not isinstance(peer_name, str) or peer_name not in site.nodes:
            continue

        peer = site.nodes[peer_name]

        neighbors.append(
            {
                "peer_name": peer_name,
                "peer_asn": site.bgp_asn,
                "peer_addr4": peer.loopback4,
                "peer_addr6": peer.loopback6,
                "update_source": "lo",
                "route_reflector_client": bool(node_name == rr and peer_name != rr),
            }
        )

    neighbors = sorted(
        neighbors,
        key=lambda item: (
            str(item.get("peer_name") or ""),
            str(item.get("peer_addr4") or ""),
            str(item.get("peer_addr6") or ""),
        ),
    )

    return {
        "loopback": {
            "ipv4": node.loopback4,
            "ipv6": node.loopback6,
        },
        "bgp": {
            "asn": site.bgp_asn,
            "neighbors": neighbors,
        },
    }


def _render_node(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
) -> Dict[str, Any]:
    role = str(node.role or "").strip()
    renderer = _renderers().get(role)
    if renderer is None:
        raise ValueError(f"No Unit renderer for role={role!r} node={node_name!r}")
    return renderer(site, node_name, node, eth_map, _node_extra(site, node_name))


def render_units(site: SiteModel) -> Tuple[Dict[str, Any], List[Dict[str, Any]], List[str]]:
    eth_maps = _build_eth_maps(site)

    nodes: Dict[str, Any] = {}
    links: List[Dict[str, Any]] = []
    bridges: List[str] = []

    for node_name in sorted(site.nodes.keys()):
        node = site.nodes[node_name]
        nodes[node_name] = _render_node(site, node_name, node, eth_maps.get(node_name, {}))

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        endpoints: List[str] = []

        for node_name, ep in sorted(link.endpoints.items()):
            if node_name not in eth_maps:
                continue

            iface = ep.get("interface")
            if iface is None:
                continue

            if iface not in eth_maps[node_name]:
                continue

            eth_index = eth_maps[node_name][iface]
            endpoint = f"{node_name}:eth{eth_index}"
            endpoints.append(endpoint)

        if len(endpoints) == 2:
            bridge = _bridge_name(f"{site.enterprise}-{site.site}-{link_name}")
            bridges.append(bridge)

            links.append(
                {
                    "endpoints": endpoints,
                    "labels": {
                        "clab.link.type": "bridge",
                        "clab.link.bridge": bridge,
                    },
                }
            )

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
            endpoint = f"{node_name}:eth{eth}"
            tenant_groups.setdefault(tenant_key, []).append(endpoint)

    for tenant in sorted(tenant_groups.keys()):
        bridge = _bridge_name(f"{site.enterprise}-{site.site}-tenant-{tenant}")
        bridges.append(bridge)

        endpoints = list(tenant_groups[tenant])
        if len(endpoints) == 1:
            host_endpoint = f"host:{_host_ifname(bridge)}"
            endpoints.append(host_endpoint)

        links.append(
            {
                "endpoints": endpoints,
                "labels": {
                    "clab.link.type": "bridge",
                    "clab.link.bridge": bridge,
                },
            }
        )

    return nodes, links, sorted(set(bridges))
