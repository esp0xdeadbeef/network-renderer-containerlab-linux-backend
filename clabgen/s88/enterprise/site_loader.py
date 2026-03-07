# ./clabgen/s88/enterprise/site_loader.py
from __future__ import annotations

from typing import Dict, List, Any
from pathlib import Path

from clabgen.solver import (
    load_solver,
    extract_enterprise_sites,
    validate_site_invariants,
    validate_routing_assumptions,
)

from clabgen.models import SiteModel, NodeModel, InterfaceModel, LinkModel


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


def _build_interfaces(
    site: Dict[str, Any],
    node_name: str,
    node_obj: Dict[str, Any],
) -> Dict[str, InterfaceModel]:
    interfaces: Dict[str, InterfaceModel] = {}

    for link_key, iface in node_obj.get("interfaces", {}).items():
        fb = _endpoint_fallbacks(site, node_name, link_key, iface)

        interfaces[link_key] = InterfaceModel(
            name=link_key,
            addr4=fb["addr4"],
            addr6=fb["addr6"],
            ll6=fb["ll6"],
            routes=_route_lists(iface),
            kind=fb["kind"],
            upstream=fb["upstream"],
        )

    return interfaces


def _build_nodes(site: Dict[str, Any]) -> Dict[str, NodeModel]:
    nodes: Dict[str, NodeModel] = {}

    for unit, node_obj in site.get("nodes", {}).items():
        interfaces = _build_interfaces(site, unit, node_obj)

        nodes[unit] = NodeModel(
            name=unit,
            role=node_obj.get("role", ""),
            routing_domain=node_obj.get("routingDomain", ""),
            interfaces=interfaces,
            containers=node_obj.get("containers", []),
        )

    return nodes


def _build_links(site: Dict[str, Any]) -> Dict[str, LinkModel]:
    links: Dict[str, LinkModel] = {}

    for lk, lo in (site.get("links", {}) or {}).items():
        links[lk] = LinkModel(
            name=lk,
            kind=lo.get("kind", "lan"),
            endpoints=lo.get("endpoints", {}),
        )

    return links


def load_sites(path: str | Path) -> Dict[str, SiteModel]:
    solver_path = Path(path)

    data = load_solver(solver_path)

    result: Dict[str, SiteModel] = {}

    for enterprise, site_name, site in extract_enterprise_sites(data):
        validate_site_invariants(
            site,
            context={"enterprise": enterprise, "site": site_name},
        )

        assumptions = validate_routing_assumptions(site)

        nodes = _build_nodes(site)
        links = _build_links(site)
        domains = site.get("domains", {})

        key = f"{enterprise}-{site_name}"

        result[key] = SiteModel(
            enterprise=enterprise,
            site=site_name,
            nodes=nodes,
            links=links,
            single_access=assumptions.get("singleAccess", ""),
            domains=domains,
        )

    return result
