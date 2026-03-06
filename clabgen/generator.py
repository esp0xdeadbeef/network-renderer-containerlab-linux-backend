from __future__ import annotations

from typing import Dict, List, Set, Any
import copy
import ipaddress

from .models import SiteModel, NodeModel, InterfaceModel
from .linux_router import render_linux_router
from .links import build_eth_index, short_bridge
from .sysctls_catalog import default_sysctls


ROLE_ORDER = [
    "access",
    "policy",
    "upstream-selector",
    "core",
    "wan-peer",
    "isp",
]


def scoped_name(site: SiteModel, unit: str) -> str:
    return f"{site.enterprise}-{site.site}-{unit}"


def _role_rank(role: str) -> int:
    for idx, r in enumerate(ROLE_ORDER):
        if r in role:
            return idx
    return len(ROLE_ORDER)


def _normalize_prefix(prefix: str) -> str:
    net = ipaddress.ip_network(prefix, strict=False)
    return str(net)


def _peer_addr(cidr: str) -> str:
    iface = ipaddress.ip_interface(cidr)
    current = iface.ip

    if isinstance(iface.network, ipaddress.IPv4Network):
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 31:
            candidates = list(iface.network)
    else:
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 127:
            candidates = list(iface.network)

    for cand in candidates:
        if cand != current:
            return f"{cand}/{iface.network.prefixlen}"

    raise ValueError(f"cannot derive peer address from {cidr}")


def _route_lists(iface: InterfaceModel) -> Dict[str, List[Dict[str, Any]]]:
    return {
        "ipv4": list((iface.routes or {}).get("ipv4", [])),
        "ipv6": list((iface.routes or {}).get("ipv6", [])),
    }


def _augment_site(site: SiteModel) -> SiteModel:
    site = copy.deepcopy(site)

    for link_name, link in list(site.links.items()):
        if link.kind != "wan":
            continue

        eps = sorted(link.endpoints.keys())
        if len(eps) != 1:
            continue

        unit = eps[0]
        ep = link.endpoints[unit]
        uplink = ep.get("uplink") or link.get("uplink") or link_name
        peer_name = f"wan-peer-{uplink}"

        if peer_name not in site.nodes:
            site.nodes[peer_name] = NodeModel(
                name=peer_name,
                role="wan-peer",
                routing_domain="",
                interfaces={},
                containers=[],
            )

        peer_ep: Dict[str, Any] = {
            "node": peer_name,
            "interface": link_name,
        }

        if ep.get("addr4"):
            peer_ep["addr4"] = _peer_addr(ep["addr4"])
        if ep.get("addr6"):
            peer_ep["addr6"] = _peer_addr(ep["addr6"])

        link.endpoints[peer_name] = peer_ep

        peer_routes4: List[Dict[str, Any]] = []
        peer_routes6: List[Dict[str, Any]] = []

        for node_name, node in site.nodes.items():
            if node_name == peer_name:
                continue

            for iface in node.interfaces.values():
                if iface.kind == "wan":
                    continue

                routes = _route_lists(iface)

                for r in routes["ipv4"]:
                    if r.get("proto") != "connected":
                        continue
                    dst = r.get("dst") or r.get("to")
                    if dst and ep.get("addr4"):
                        peer_routes4.append(
                            {
                                "dst": _normalize_prefix(dst),
                                "via4": ep["addr4"].split("/")[0],
                            }
                        )

                for r in routes["ipv6"]:
                    if r.get("proto") != "connected":
                        continue
                    dst = r.get("dst") or r.get("to")
                    if dst and ep.get("addr6"):
                        peer_routes6.append(
                            {
                                "dst": _normalize_prefix(dst),
                                "via6": ep["addr6"].split("/")[0],
                            }
                        )

        if ep.get("addr4"):
            peer_routes4 = [
                r
                for r in peer_routes4
                if r.get("dst")
                != str(ipaddress.ip_interface(ep["addr4"]).network)
            ]

        if ep.get("addr6"):
            peer_routes6 = [
                r
                for r in peer_routes6
                if r.get("dst")
                != str(ipaddress.ip_interface(ep["addr6"]).network)
            ]

        site.nodes[peer_name].interfaces[link_name] = InterfaceModel(
            name=link_name,
            addr4=peer_ep.get("addr4"),
            addr6=peer_ep.get("addr6"),
            ll6=None,
            kind="wan",
            upstream=uplink,
            routes={
                "ipv4": peer_routes4,
                "ipv6": peer_routes6,
            },
        )

    return site


def generate_topology(site: SiteModel) -> Dict[str, Any]:
    site = _augment_site(copy.deepcopy(site))

    defaults = {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "sysctls": default_sysctls(),
    }

    if not site.nodes or not site.links:
        return {
            "name": f"{site.enterprise}-{site.site}",
            "topology": {
                "defaults": defaults,
                "nodes": {},
                "links": [],
            },
            "bridges": [],
        }

    rendered_nodes: Dict[str, Dict[str, Any]] = {}
    rendered_links: List[Dict[str, Any]] = []
    bridges: Set[str] = set()

    eth_index = build_eth_index(site)

    sorted_units = sorted(
        site.nodes.items(),
        key=lambda kv: (_role_rank(kv[1].role or ""), kv[0]),
    )

    projected_nodes: Set[str] = set()
    projected_links: Set[str] = set()

    for unit, node in sorted_units:
        full_name = scoped_name(site, unit)

        node_dict = {
            "name": unit,
            "role": node.role or "",
            "interfaces": {
                ifname: {
                    "addr4": iface.addr4,
                    "addr6": iface.addr6,
                    "ll6": iface.ll6,
                    "kind": iface.kind,
                    "upstream": iface.upstream,
                    "routes": {
                        "ipv4": list((iface.routes or {}).get("ipv4", [])),
                        "ipv6": list((iface.routes or {}).get("ipv6", [])),
                    },
                }
                for ifname, iface in node.interfaces.items()
            },
        }

        rendered = render_linux_router(node_dict, eth_index.get(unit, {}))

        node_def: Dict[str, Any] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
        }

        if rendered.get("exec"):
            node_def["exec"] = [str(cmd) for cmd in rendered["exec"]]

        rendered_nodes[full_name] = node_def
        projected_nodes.add(unit)

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        eps = sorted(link.endpoints.keys())

        if len(eps) != 2:
            raise ValueError(
                f"link '{link_name}' did not project symmetrically: expected 2 endpoints, got {len(eps)}"
            )

        bridge = short_bridge(f"{site.enterprise}-{site.site}-{link_name}")
        bridges.add(bridge)

        endpoints = []
        for unit in eps:
            if unit not in eth_index or link_name not in eth_index[unit]:
                raise ValueError(
                    f"missing interface projection for node '{unit}' link '{link_name}'"
                )

            full_name = scoped_name(site, unit)
            eth_num = eth_index[unit][link_name]
            endpoints.append(f"{full_name}:eth{eth_num}")

        rendered_links.append(
            {
                "endpoints": endpoints,
                "labels": {
                    "clab.link.type": "bridge",
                    "clab.link.bridge": bridge,
                },
            }
        )
        projected_links.add(link_name)

    missing_nodes = sorted(set(site.nodes.keys()) - projected_nodes)
    missing_links = sorted(set(site.links.keys()) - projected_links)
    if missing_nodes or missing_links:
        raise ValueError(
            f"unprojected solver elements: nodes={missing_nodes} links={missing_links}"
        )

    return {
        "name": f"{site.enterprise}-{site.site}",
        "topology": {
            "defaults": defaults,
            "nodes": rendered_nodes,
            "links": rendered_links,
        },
        "bridges": sorted(list(bridges)),
    }
