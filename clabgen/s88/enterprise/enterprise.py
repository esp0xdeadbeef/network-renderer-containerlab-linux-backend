# ./clabgen/s88/enterprise/enterprise.py
from __future__ import annotations

from typing import Dict, Any, List
import copy
import hashlib

from clabgen.models import SiteModel
from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.enterprise.inject_wan_peers import inject_emulated_wan_peers
from clabgen.s88.enterprise.inject_clients import inject_clients
from clabgen.s88.CM.base import CM_BY_ROLE


def _short_bridge(name: str) -> str:
    h = hashlib.blake2s(name.encode(), digest_size=6).hexdigest()
    return f"br-{h}"


def _build_eth_maps(site: SiteModel) -> Dict[str, Dict[str, int]]:
    eth_maps: Dict[str, Dict[str, int]] = {n: {} for n in site.nodes}
    counters: Dict[str, int] = {n: 1 for n in site.nodes}

    for link_name, link in site.links.items():
        for ep_name, ep in link.endpoints.items():
            node = ep["node"]

            if node not in eth_maps:
                eth_maps[node] = {}
                counters[node] = 1

            if ep_name not in eth_maps[node]:
                eth_maps[node][ep_name] = counters[node]
                counters[node] += 1

    return eth_maps


def generate_topology(site: SiteModel) -> Dict[str, Any]:
    site = copy.deepcopy(site)

    inject_emulated_wan_peers(site)
    inject_clients(site)

    eth_maps = _build_eth_maps(site)

    nodes: Dict[str, Any] = {}
    links: List[Dict[str, Any]] = []
    bridges: List[str] = []

    for node_name, node in site.nodes.items():
        exec_cmds: List[str] = []

        if node.role in CM_BY_ROLE:
            for renderer in CM_BY_ROLE[node.role]:
                exec_cmds.extend(renderer(node_name, node.role))

        for ifname, iface in node.interfaces.items():
            eth = eth_maps[node_name][ifname]

            if iface.addr4:
                exec_cmds.append(
                    f"ip addr replace {iface.addr4} dev eth{eth}"
                )

            if iface.addr6:
                exec_cmds.append(
                    f"ip -6 addr replace {iface.addr6} dev eth{eth}"
                )

            exec_cmds.append(f"ip link set eth{eth} up")

            if iface.routes:
                for route in iface.routes.get("ipv4", []):
                    exec_cmds.append(
                        f"ip route replace {route['dst']} via {route['via4']} dev eth{eth} onlink"
                    )

                for route in iface.routes.get("ipv6", []):
                    exec_cmds.append(
                        f"ip -6 route replace {route['dst']} via {route['via6']} dev eth{eth} onlink"
                    )

        nodes[node_name] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
            "exec": exec_cmds,
        }

    for link_name, link in site.links.items():
        bridge = _short_bridge(link_name)
        bridges.append(bridge)

        endpoints: List[str] = []

        for ep_name, ep in link.endpoints.items():
            node = ep["node"]
            eth = eth_maps[node][ep_name]
            endpoints.append(f"{node}:eth{eth}")

        links.append(
            {
                "endpoints": endpoints,
                "labels": {
                    "clab.link.type": "bridge",
                    "clab.link.bridge": bridge,
                },
            }
        )

    return {
        "topology": {
            "nodes": nodes,
            "links": links,
        },
        "bridges": bridges,
    }


class Enterprise:
    def __init__(self, solver_json: Dict[str, Any]) -> None:
        self.solver_json = solver_json
        self.sites = load_sites(solver_json)

    def render(self) -> Dict[str, Any]:
        merged = {
            "topology": {
                "nodes": {},
                "links": [],
            },
            "bridges": [],
        }

        for site_key in self.sites:
            topo = generate_topology(self.sites[site_key])

            merged["topology"]["nodes"].update(topo["topology"]["nodes"])
            merged["topology"]["links"].extend(topo["topology"]["links"])
            merged["bridges"].extend(topo["bridges"])

        return merged
