# ./clabgen/s88/enterprise/enterprise.py
from __future__ import annotations

from typing import Dict, Any, List
from pathlib import Path
import copy
import hashlib

from clabgen.models import SiteModel
from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.enterprise.inject_wan_peers import inject_emulated_wan_peers
from clabgen.s88.enterprise.inject_clients import inject_clients
from clabgen.s88.Unit.base import render_units


MAX_NODE_NAME = 64


def _hash5(value: str) -> str:
    return hashlib.blake2s(value.encode(), digest_size=3).hexdigest()[:5]


def _tail_tokens(value: str, max_len: int) -> str:
    if max_len <= 0:
        return ""

    if len(value) <= max_len:
        return value

    parts = [p for p in value.split("-") if p]
    if not parts:
        return value[-max_len:]

    selected: List[str] = []
    total = 0

    for part in reversed(parts):
        extra = len(part) + (1 if selected else 0)
        if total + extra > max_len:
            break
        selected.append(part)
        total += extra

    if not selected:
        return value[-max_len:]

    return "-".join(reversed(selected))


def _scoped_node_name(site: SiteModel, node_name: str) -> str:
    enterprise = site.enterprise
    site_name = site.site

    candidates = [
        f"{enterprise}-{site_name}-{node_name}",
        f"{_hash5(enterprise)}-{site_name}-{node_name}",
        f"{_hash5(enterprise)}-{_hash5(site_name)}-{node_name}",
    ]

    for candidate in candidates:
        if len(candidate) <= MAX_NODE_NAME:
            return candidate

    prefix = f"{_hash5(enterprise)}-{_hash5(site_name)}-"
    remaining = MAX_NODE_NAME - len(prefix)

    if remaining <= 0:
        return prefix[:MAX_NODE_NAME]

    readable_tail = _tail_tokens(node_name, remaining)
    candidate = f"{prefix}{readable_tail}"

    if len(candidate) <= MAX_NODE_NAME:
        return candidate

    return candidate[:MAX_NODE_NAME]


def generate_topology(site: SiteModel) -> Dict[str, Any]:
    site = copy.deepcopy(site)

    inject_emulated_wan_peers(site)
    inject_clients(site)

    nodes, links, bridges = render_units(site)

    return {
        "name": f"{site.enterprise}-{site.site}",
        "topology": {
            "defaults": {
                "kind": "linux",
                "image": "clab-frr-plus-tooling:latest",
            },
            "nodes": nodes,
            "links": links,
        },
        "bridges": bridges,
        "bridge_control_modules": {},
        "solver_meta": dict(site.solver_meta or {}),
    }


class Enterprise:
    def __init__(self, sites: Dict[str, SiteModel]) -> None:
        self.sites = sites

    @classmethod
    def from_solver_json(
        cls,
        solver_json: str | Path,
        renderer_inventory: Dict[str, Any] | None = None,
    ) -> "Enterprise":
        sites = load_sites(
            solver_json,
            renderer_inventory=renderer_inventory,
        )
        return cls(sites)

    def render(self) -> Dict[str, Any]:
        merged_nodes: Dict[str, Any] = {}
        merged_links: List[Dict[str, Any]] = []
        merged_bridges: List[str] = []

        defaults: Dict[str, Any] | None = None
        solver_meta: Dict[str, Any] | None = None

        for site_key in sorted(self.sites.keys()):
            site = self.sites[site_key]
            topo = generate_topology(site)

            if defaults is None:
                defaults = topo["topology"]["defaults"]

            if solver_meta is None:
                solver_meta = dict(topo.get("solver_meta", {}) or {})

            node_name_map: Dict[str, str] = {}

            for node_name in sorted(topo["topology"]["nodes"].keys()):
                rendered_node_name = _scoped_node_name(site, node_name)

                if rendered_node_name in merged_nodes:
                    raise ValueError(f"duplicate rendered node '{rendered_node_name}'")

                node_name_map[node_name] = rendered_node_name
                merged_nodes[rendered_node_name] = copy.deepcopy(
                    topo["topology"]["nodes"][node_name]
                )

                print(
                    "[enterprise.render] node-map:"
                    f" site={site.enterprise}/{site.site}"
                    f" source={node_name}"
                    f" rendered={rendered_node_name}"
                )

            for link_def in topo["topology"]["links"]:
                link_copy = copy.deepcopy(link_def)
                endpoints = list(link_copy.get("endpoints", []))
                rewritten_endpoints: List[str] = []

                for endpoint in endpoints:
                    if not isinstance(endpoint, str) or ":" not in endpoint:
                        rewritten_endpoints.append(endpoint)
                        continue

                    endpoint_node_name, ifname = endpoint.split(":", 1)

                    if endpoint_node_name == "host":
                        rewritten_endpoints.append(endpoint)
                        continue

                    rendered_node_name = node_name_map.get(endpoint_node_name)
                    if rendered_node_name is None:
                        raise ValueError(
                            f"link references unknown rendered node '{endpoint_node_name}'"
                        )

                    rewritten_endpoints.append(f"{rendered_node_name}:{ifname}")

                link_copy["endpoints"] = rewritten_endpoints

                print(
                    "[enterprise.render] rewritten-link:"
                    f" site={site.enterprise}/{site.site}"
                    f" endpoints={rewritten_endpoints}"
                    f" labels={link_copy.get('labels', {})}"
                )

                merged_links.append(link_copy)

            merged_bridges.extend(list(topo.get("bridges", [])))

        return {
            "name": "fabric",
            "topology": {
                "defaults": defaults or {},
                "nodes": merged_nodes,
                "links": merged_links,
            },
            "bridges": sorted(set(merged_bridges)),
            "bridge_control_modules": {},
            "solver_meta": solver_meta or {},
        }
