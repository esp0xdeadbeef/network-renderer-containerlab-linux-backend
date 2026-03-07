# ./clabgen/s88/enterprise/enterprise.py
from __future__ import annotations

from typing import Dict, Any, List
from pathlib import Path

from clabgen.generator import generate_topology
from clabgen.models import SiteModel
from clabgen.s88.enterprise.site_loader import load_sites


class Enterprise:
    def __init__(self, sites: Dict[str, SiteModel]) -> None:
        self.sites = sites

    @classmethod
    def from_solver_json(cls, solver_json: str | Path) -> "Enterprise":
        sites = load_sites(solver_json)
        return cls(sites)

    def render(self) -> Dict[str, Any]:
        merged_nodes: Dict[str, Any] = {}
        merged_links: List[Dict[str, Any]] = []
        merged_bridges: List[str] = []

        defaults: Dict[str, Any] | None = None

        for site_key in sorted(self.sites.keys()):
            topo = generate_topology(self.sites[site_key])

            if defaults is None:
                defaults = topo["topology"]["defaults"]

            for node_name, node_def in topo["topology"]["nodes"].items():
                if node_name in merged_nodes:
                    raise ValueError(f"duplicate rendered node '{node_name}'")
                merged_nodes[node_name] = node_def

            merged_links.extend(topo["topology"]["links"])
            merged_bridges.extend(topo["bridges"])

        return {
            "name": "fabric",
            "topology": {
                "defaults": defaults or {},
                "nodes": merged_nodes,
                "links": merged_links,
            },
            "bridges": sorted(set(merged_bridges)),
        }
