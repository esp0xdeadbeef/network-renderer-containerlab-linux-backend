from __future__ import annotations

from typing import Any, Dict


def _transit_adjacencies(site: Dict[str, Any]) -> list[Any]:
    transit = site.get("transit") or {}
    if not isinstance(transit, dict):
        return []

    adjacencies = transit.get("adjacencies") or []
    return adjacencies if isinstance(adjacencies, list) else []


def _adjacency_endpoints(adjacency: Dict[str, Any]) -> Dict[str, Any]:
    endpoints_out: Dict[str, Any] = {}
    endpoints = adjacency.get("endpoints") or []
    if not isinstance(endpoints, list):
        return endpoints_out

    for endpoint in endpoints:
        if not isinstance(endpoint, dict):
            continue
        unit = endpoint.get("unit")
        if not isinstance(unit, str) or not unit:
            continue
        endpoints_out[unit] = {
            "node": unit,
            "interface": adjacency.get("link") or adjacency.get("name"),
        }

    return endpoints_out


def add_transit_links(
    site: Dict[str, Any],
    links: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> None:
    for adjacency in _transit_adjacencies(site):
        if not isinstance(adjacency, dict):
            continue

        link_name = adjacency.get("link") or adjacency.get("name")
        if not isinstance(link_name, str) or not link_name:
            continue

        links[link_name] = {
            "kind": adjacency.get("kind") or "p2p",
            "bridge": link_bridges.get(link_name),
            "hostUplink": link_host_uplinks.get(link_name, {}),
            "endpoints": _adjacency_endpoints(adjacency),
        }
