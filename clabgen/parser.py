from __future__ import annotations

from typing import Dict, List, Any
from pathlib import Path

from clabgen.solver import (
    load_solver,
    extract_enterprise_sites,
    validate_site_invariants,
    validate_routing_assumptions,
)

from .models import SiteModel, NodeModel, InterfaceModel, LinkModel


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes = iface.get("routes")
    if isinstance(routes, dict):
        return {
            "ipv4": list(routes.get("ipv4", [])),
            "ipv6": list(routes.get("ipv6", [])),
        }

    return {
        "ipv4": list(iface.get("routes4", [])),
        "ipv6": list(iface.get("routes6", [])),
    }


def _endpoint_fallbacks(
    site: Dict[str, Any],
    node_name: str,
    ifname: str,
    iface: Dict[str, Any],
) -> Dict[str, Any]:
    link = (site.get("links", {}) or {}).get(ifname, {})
    ep = (
        ((link.get("endpoints", {}) or {}).get(node_name, {}))
        if isinstance(link, dict)
        else {}
    )

    return {
        "addr4": iface.get("addr4") or ep.get("addr4"),
        "addr6": iface.get("addr6") or ep.get("addr6"),
        "ll6": iface.get("ll6") or ep.get("ll6"),
        "kind": iface.get("kind") or link.get("kind"),
        "upstream": (
            iface.get("upstream")
            or iface.get("uplink")
            or ep.get("upstream")
            or ep.get("uplink")
            or link.get("upstream")
            or link.get("uplink")
        ),
    }


def parse_solver(path: str | Path) -> Dict[str, SiteModel]:
    solver_path = Path(path)

    data = load_solver(solver_path)
    sites_raw = extract_enterprise_sites(data)

    result: Dict[str, SiteModel] = {}

    for ent, site_name, site in sites_raw:
        if "nodes" not in site or "links" not in site:
            nodes: Dict[str, NodeModel] = {}
            links: Dict[str, LinkModel] = {}
            domains = site.get("domains", {})
            assumptions = {"singleAccess": ""}
        else:
            validate_site_invariants(
                site,
                context={"enterprise": ent, "site": site_name},
            )
            assumptions = validate_routing_assumptions(site)

            nodes = {}
            for unit, node_obj in site["nodes"].items():
                interfaces: Dict[str, InterfaceModel] = {}
                for link_key, iface in node_obj.get("interfaces", {}).items():
                    fb = _endpoint_fallbacks(site, unit, link_key, iface)
                    interfaces[link_key] = InterfaceModel(
                        name=link_key,
                        addr4=fb["addr4"],
                        addr6=fb["addr6"],
                        ll6=fb["ll6"],
                        routes=_route_lists(iface),
                        kind=fb["kind"],
                        upstream=fb["upstream"],
                    )

                nodes[unit] = NodeModel(
                    name=unit,
                    role=node_obj.get("role", ""),
                    routing_domain=node_obj.get("routingDomain", ""),
                    interfaces=interfaces,
                    containers=node_obj.get("containers", []),
                )

            links = {}
            for lk, lo in site["links"].items():
                links[lk] = LinkModel(
                    name=lk,
                    kind=lo.get("kind", "lan"),
                    endpoints=lo.get("endpoints", {}),
                )

            domains = site.get("domains", {})

        key = f"{ent}-{site_name}"
        result[key] = SiteModel(
            enterprise=ent,
            site=site_name,
            nodes=nodes,
            links=links,
            single_access=assumptions.get("singleAccess", ""),
            domains=domains,
        )

    return result
