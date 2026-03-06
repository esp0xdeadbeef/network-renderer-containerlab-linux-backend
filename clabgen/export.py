# ./clabgen/export.py
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

import yaml

from clabgen.generator import generate_topology
from clabgen.parser import parse_solver


def _combine_sites(sites: Dict[str, Any]) -> Dict[str, Any]:
    merged_nodes: Dict[str, Any] = {}
    merged_links: List[Dict[str, Any]] = []
    merged_bridges: List[str] = []

    defaults: Dict[str, Any] | None = None

    for site_key in sorted(sites.keys()):
        topo = generate_topology(sites[site_key])

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


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    solver_json = Path(solver_json)
    topology_out = Path(topology_out)
    bridges_out = Path(bridges_out)

    with solver_json.open() as f:
        json.load(f)

    parsed_sites = parse_solver(solver_json)
    merged = _combine_sites(parsed_sites)

    topo_yaml = yaml.safe_dump(
        {
            "name": merged["name"],
            "topology": merged["topology"],
        },
        sort_keys=False,
    )

    topology_out.write_text(f"# fabric.clab.yml\n{topo_yaml}")

    bridges_out.write_text(
        "{ lib, ... }:\n{\n  bridges = [\n"
        + "\n".join(f'    "{b}"' for b in merged["bridges"])
        + "\n  ];\n}\n"
    )
