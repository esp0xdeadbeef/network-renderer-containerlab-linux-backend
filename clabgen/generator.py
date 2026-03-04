from __future__ import annotations

from typing import Dict, List, Set
import copy
import json
from pathlib import Path

from .models import SiteModel
from .linux_router import render_linux_router
from .links import build_eth_index, short_bridge
from .isp import ensure_isp_node
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


def _load_raw_site(site: SiteModel) -> Dict:
    solver_path = Path("output-network-solver.json")
    if not solver_path.exists():
        return {}

    with solver_path.open() as f:
        data = json.load(f)

    return (
        data.get("sites", {})
        .get(site.enterprise, {})
        .get(site.site, {})
    )


def _role_rank(role: str) -> int:
    for idx, r in enumerate(ROLE_ORDER):
        if r in role:
            return idx
    return len(ROLE_ORDER)


def generate_topology(site: SiteModel) -> Dict:
    site = copy.deepcopy(site)

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

    rendered_nodes: Dict[str, Dict] = {}
    rendered_links: List[Dict] = []
    bridges: Set[str] = set()

    eth_index = build_eth_index(site)

    sorted_units = sorted(
        site.nodes.items(),
        key=lambda kv: (_role_rank(kv[1].role or ""), kv[0]),
    )

    for unit, node in sorted_units:
        full_name = scoped_name(site, unit)

        if node.role == "isp":
            ensure_isp_node(rendered_nodes, full_name, None)
            continue

        node_dict = {
            "name": unit,
            "role": node.role or "",
            "interfaces": {
                ifname: {
                    "addr4": iface.addr4,
                    "addr6": iface.addr6,
                    "routes4": iface.routes4,
                    "routes6": iface.routes6,
                }
                for ifname, iface in node.interfaces.items()
            }
        }

        rendered = render_linux_router(node_dict, eth_index.get(unit, {}))

        node_def: Dict[str, object] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
        }

        if rendered.get("exec"):
            node_def["exec"] = [str(cmd) for cmd in rendered["exec"]]

        rendered_nodes[full_name] = node_def

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        eps = sorted(link.endpoints.keys())
        if len(eps) != 2:
            continue

        bridge = short_bridge(f"{site.enterprise}-{site.site}-{link_name}")
        bridges.add(bridge)

        endpoints = []
        for unit in eps:
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

    return {
        "name": f"{site.enterprise}-{site.site}",
        "topology": {
            "defaults": defaults,
            "nodes": rendered_nodes,
            "links": rendered_links,
        },
        "bridges": sorted(list(bridges)),
    }
