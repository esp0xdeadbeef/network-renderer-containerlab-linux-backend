from __future__ import annotations

from typing import Any, Dict, List, Set
import json

from clabgen.models import SiteModel
from clabgen.s88.site.access_tenants import access_node_tenants


def _link_sort_key(item):
    return item[0]


def policy_peer_map(site: SiteModel, policy_node_name: str, eth_map: Dict[str, str]):
    results = []
    for _, link in sorted(site.links.items(), key=_link_sort_key):
        endpoints = link.endpoints
        local = endpoints.get(policy_node_name)
        if not isinstance(local, dict):
            continue
        iface = local.get("interface")
        if iface not in eth_map:
            raise RuntimeError(
                f"missing target interface mapping for interface {iface}\n"
                + json.dumps(local, indent=2, default=str)
            )
        peers: List[str] = []
        for endpoint_node_name in endpoints:
            if endpoint_node_name != policy_node_name:
                peers.append(endpoint_node_name)
        if not peers:
            continue
        results.append(
            {
                "target_ifname": eth_map[iface],
                "peer_name": peers[0],
                "link": link.name,
                "policy_iface": iface,
            }
        )
    return results


def add_interface_tag(
    interface_tags: Dict[str, Any], iface_name: str, tag: str
) -> None:
    if not isinstance(tag, str) or not tag:
        return
    current = interface_tags.get(iface_name)
    if current is None:
        interface_tags[iface_name] = tag
        return
    if isinstance(current, str):
        values = [current]
    elif isinstance(current, list):
        values = []
        for value in current:
            if isinstance(value, str) and value:
                values.append(value)
    else:
        values = []
    if tag not in values:
        values.append(tag)
    interface_tags[iface_name] = values[0] if len(values) == 1 else sorted(values)


def interface_tag_values(interface_tags: Dict[str, Any]) -> Set[str]:
    values: Set[str] = set()
    for raw in interface_tags.values():
        if isinstance(raw, str) and raw:
            values.add(raw)
        elif isinstance(raw, list):
            for item in raw:
                if isinstance(item, str) and item:
                    values.add(item)
    return values


def _attrs(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _link_model(site: SiteModel, peer: Dict[str, Any]):
    link_name = peer.get("link")
    if not isinstance(link_name, str):
        return None
    return site.links.get(link_name)


def _lane_access_unit(site: SiteModel, peer: Dict[str, Any]) -> str | None:
    link = _link_model(site, peer)
    if link is None:
        return None
    lane = _attrs(getattr(link, "lane", None))
    lane_meta = _attrs(getattr(link, "lane_meta", None))
    access = lane.get("access") or lane_meta.get("access")
    return access if isinstance(access, str) and access else None


def _lane_uplinks(site: SiteModel, peer: Dict[str, Any]) -> List[str]:
    link = _link_model(site, peer)
    if link is None:
        return []
    lane = _attrs(getattr(link, "lane", None))
    lane_meta = _attrs(getattr(link, "lane_meta", None))
    values: List[str] = []
    for item in getattr(link, "uplinks", []) or []:
        if isinstance(item, str) and item:
            values.append(item)
    for value in (
        lane.get("uplink"),
        lane_meta.get("uplink"),
        *(lane.get("uplinks") or []),
        *(lane_meta.get("uplinks") or []),
    ):
        if isinstance(value, str) and value:
            values.append(value)
    return sorted(set(values))


def tag_from_peer_role(
    site: SiteModel,
    interface_tags: Dict[str, Any],
    iface_name: str,
    peer: Dict[str, Any],
) -> bool:
    peer_node = site.nodes.get(peer["peer_name"])
    if peer_node is None:
        raise RuntimeError(
            f"peer node missing: {peer['peer_name']}\n"
            + json.dumps(sorted(site.nodes.keys()), indent=2)
        )
    if peer_node.role == "access":
        tenants = access_node_tenants(site, peer_node)
        if len(tenants) != 1:
            raise RuntimeError(
                "policy-facing access node must resolve to exactly one tenant\n"
                + json.dumps(
                    {"peer_node": peer_node.name, "tenants": tenants}, indent=2
                )
            )
        add_interface_tag(interface_tags, iface_name, tenants[0])
        return True
    if peer_node.role == "upstream-selector":
        uplinks = _lane_uplinks(site, peer)
        for uplink in uplinks:
            add_interface_tag(interface_tags, iface_name, uplink)
        return True
    if peer_node.role == "downstream-selector":
        access_unit = _lane_access_unit(site, peer)
        access_node = None
        if access_unit:
            access_node = site.nodes.get(access_unit)
        if access_node is not None and access_node.role == "access":
            for tenant in access_node_tenants(site, access_node):
                add_interface_tag(interface_tags, iface_name, tenant)
            return True
    if peer_node.role == "core":
        wan_uplink_set: set[str] = set()
        for iface in peer_node.interfaces.values():
            upstream = getattr(iface, "upstream", None)
            if getattr(iface, "kind", None) == "wan" and isinstance(upstream, str):
                wan_uplink_set.add(upstream)
        wan_uplinks = sorted(wan_uplink_set)
        for uplink in wan_uplinks:
            add_interface_tag(interface_tags, iface_name, uplink)
        return True
    return False
