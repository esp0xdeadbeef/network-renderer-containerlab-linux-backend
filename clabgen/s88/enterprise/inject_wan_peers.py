# ./clabgen/s88/enterprise/inject_wan_peers.py
from __future__ import annotations

from typing import Dict, Any
import hashlib
import ipaddress

from clabgen.models import SiteModel, NodeModel, InterfaceModel


MAX_NODE_NAME = 32
MAX_IFACE_NAME = 15


def _ip_only(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None

    try:
        return str(ipaddress.ip_interface(value).ip)
    except ValueError:
        try:
            return str(ipaddress.ip_address(value))
        except ValueError:
            return None


def _short_node(link_name: str, node_name: str, iface_name: str) -> str:
    digest = hashlib.blake2s(
        f"{link_name}:{node_name}:{iface_name}".encode(),
        digest_size=6,
    ).hexdigest()

    name = f"wanp-{digest}"

    if len(name) > MAX_NODE_NAME:
        name = name[:MAX_NODE_NAME]

    return name


def _short_iface(link_name: str) -> str:
    digest = hashlib.blake2s(link_name.encode(), digest_size=4).hexdigest()
    name = f"wan-{digest}"

    if len(name) > MAX_IFACE_NAME:
        name = name[:MAX_IFACE_NAME]

    return name


def inject_emulated_wan_peers(site: SiteModel) -> None:
    new_nodes: Dict[str, NodeModel] = {}

    for link_name, link in list(site.links.items()):
        if getattr(link, "kind", None) != "wan":
            continue
        if getattr(link, "host_uplink", None):
            continue

        endpoints = dict(getattr(link, "endpoints", {}) or {})
        if len(endpoints) != 1:
            continue

        local_node_name = ""
        local_ep: Dict[str, Any] = {}
        for endpoint_node_name, endpoint_data in endpoints.items():
            local_node_name = endpoint_node_name
            local_ep = endpoint_data
            break

        if not isinstance(local_ep, dict):
            continue

        iface_name = local_ep.get("interface")
        if not isinstance(iface_name, str) or not iface_name:
            continue

        local_node = site.nodes.get(local_node_name)
        if local_node is None:
            continue

        local_iface = local_node.interfaces.get(iface_name)
        if local_iface is None:
            continue

        peer_name = _short_node(link_name, local_node_name, iface_name)

        if peer_name in site.nodes or peer_name in new_nodes:
            continue

        peer_iface = _short_iface(link_name)

        peer_addr4 = local_ep.get("peerAddr4")
        peer_addr6 = local_ep.get("peerAddr6")

        upstream = (
            local_ep.get("uplink")
            or local_ep.get("upstream")
            or getattr(local_iface, "upstream", None)
        )

        peer_node = NodeModel(
            name=peer_name,
            role="wan-peer",
            routing_domain=getattr(local_node, "routing_domain", ""),
            interfaces={
                peer_iface: InterfaceModel(
                    name=peer_iface,
                    addr4=peer_addr4 if isinstance(peer_addr4, str) else None,
                    addr6=peer_addr6 if isinstance(peer_addr6, str) else None,
                    kind="wan",
                    upstream=upstream if isinstance(upstream, str) else None,
                )
            },
        )

        new_nodes[peer_name] = peer_node

        link.endpoints[peer_name] = {
            "node": peer_name,
            "interface": peer_iface,
            "addr4": peer_addr4,
            "addr6": peer_addr6,
            "kind": "wan",
            "uplink": upstream,
            "upstream": upstream,
        }

        print(
            "[inject_wan_peers] endpoint created:"
            f" link={link_name}"
            f" local={local_node_name}:{iface_name}"
            f" peer={peer_name}:{peer_iface}"
        )

    site.nodes.update(new_nodes)
