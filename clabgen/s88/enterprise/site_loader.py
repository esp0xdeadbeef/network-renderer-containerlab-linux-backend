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
    if not isinstance(routes, dict):
        raise ValueError("interface.routes must be an object")

    ipv4 = routes.get("ipv4", [])
    ipv6 = routes.get("ipv6", [])

    if not isinstance(ipv4, list):
        raise ValueError("interface.routes.ipv4 must be an array")

    if not isinstance(ipv6, list):
        raise ValueError("interface.routes.ipv6 must be an array")

    return {
        "ipv4": list(ipv4),
        "ipv6": list(ipv6),
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
            containers=list(node_obj.get("containers", [])),
            isolated=bool(node_obj.get("isolated", False)),
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


def _ownership_endpoint_tenants(ownership: Dict[str, Any]) -> Dict[str, str]:
    result: Dict[str, str] = {}

    endpoints = ownership.get("endpoints", [])
    if endpoints is None:
        return result
    if not isinstance(endpoints, list):
        raise ValueError("ownership.endpoints must be an array")

    for endpoint in endpoints:
        if not isinstance(endpoint, dict):
            continue

        name = endpoint.get("name")
        tenant = endpoint.get("tenant")

        if not isinstance(name, str) or not name:
            raise ValueError("ownership.endpoints[].name must be a non-empty string")
        if not isinstance(tenant, str) or not tenant:
            raise ValueError(
                f"ownership.endpoints[{name!r}].tenant must be a non-empty string"
            )

        result[name] = tenant

    return result


def _normalize_renderer_inventory(renderer_inventory: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(renderer_inventory, dict):
        raise ValueError("renderer inventory must be an object")

    hosts = renderer_inventory.get("hosts", {})
    if not isinstance(hosts, dict):
        raise ValueError("renderer inventory 'hosts' must be an object")

    normalized_hosts: Dict[str, Dict[str, Any]] = {}

    for host_name, host in hosts.items():
        if not isinstance(host_name, str) or not host_name:
            raise ValueError("renderer inventory host names must be non-empty strings")
        if not isinstance(host, dict):
            raise ValueError(f"renderer inventory host {host_name!r} must be an object")

        attach_node = host.get("attach_node")
        attach_network = host.get("attach_network")

        if not isinstance(attach_node, str) or not attach_node:
            raise ValueError(
                f"renderer inventory host {host_name!r}.attach_node must be a non-empty string"
            )
        if not isinstance(attach_network, str) or not attach_network:
            raise ValueError(
                f"renderer inventory host {host_name!r}.attach_network must be a non-empty string"
            )

        normalized_hosts[host_name] = dict(host)

    return {"hosts": normalized_hosts}


def _service_provider_names(raw_policy: Dict[str, Any]) -> List[str]:
    result: List[str] = []

    services = raw_policy.get("services", [])
    if not isinstance(services, list):
        return result

    for service in services:
        if not isinstance(service, dict):
            continue

        providers = service.get("providers", [])
        if not isinstance(providers, list):
            continue

        for provider in providers:
            if isinstance(provider, str) and provider:
                result.append(provider)

    return sorted(set(result))


def _validate_renderer_inventory_for_site(
    *,
    enterprise: str,
    site_name: str,
    site: Dict[str, Any],
    renderer_inventory: Dict[str, Any],
) -> Dict[str, Any]:
    normalized_inventory = _normalize_renderer_inventory(renderer_inventory)
    hosts = normalized_inventory["hosts"]
    site_nodes = site.get("nodes", {})
    if not isinstance(site_nodes, dict):
        raise ValueError(
            f"enterprise.{enterprise}.site.{site_name}.nodes must be an object"
        )

    raw_policy = dict(site.get("communicationContract", {}) or {})
    ownership = dict(site.get("ownership", {}) or {})
    endpoint_tenants = _ownership_endpoint_tenants(ownership)

    required_hosts = set(endpoint_tenants.keys())
    required_hosts.update(_service_provider_names(raw_policy))

    for host_name in sorted(required_hosts):
        host = hosts.get(host_name)
        if not isinstance(host, dict):
            raise ValueError(
                f"renderer inventory missing host placement for endpoint/provider "
                f"{host_name!r} in {enterprise}/{site_name}"
            )

        attach_node = host.get("attach_node")
        attach_network = host.get("attach_network")

        if attach_node not in site_nodes:
            raise ValueError(
                f"renderer inventory host {host_name!r} references missing "
                f"attach_node {attach_node!r} in {enterprise}/{site_name}"
            )

        if not isinstance(attach_network, str) or not attach_network:
            raise ValueError(
                f"renderer inventory host {host_name!r} has invalid "
                f"attach_network in {enterprise}/{site_name}"
            )

        ownership_tenant = endpoint_tenants.get(host_name)
        if ownership_tenant is not None and attach_network != ownership_tenant:
            raise ValueError(
                f"renderer inventory tenant mismatch for endpoint {host_name!r} "
                f"in {enterprise}/{site_name}: attach_network={attach_network!r} "
                f"ownership.tenant={ownership_tenant!r}"
            )

    return normalized_inventory


def _provider_zone_map(
    *,
    enterprise: str,
    site_name: str,
    raw_policy: Dict[str, Any],
    raw_ownership: Dict[str, Any],
    renderer_inventory: Dict[str, Any],
) -> Dict[str, str]:
    services = raw_policy.get("services", [])
    if not isinstance(services, list):
        raise ValueError(
            f"communicationContract.services must be an array in {enterprise}/{site_name}"
        )

    endpoint_tenants = _ownership_endpoint_tenants(raw_ownership)
    hosts = dict(renderer_inventory.get("hosts", {}) or {})
    result: Dict[str, str] = {}

    for service in services:
        if not isinstance(service, dict):
            continue

        service_name = service.get("name")
        providers = service.get("providers", [])

        if not isinstance(service_name, str) or not service_name:
            continue

        if not isinstance(providers, list):
            raise ValueError(
                f"service {service_name!r}.providers must be an array in {enterprise}/{site_name}"
            )

        resolved_zone: str | None = None

        for provider in providers:
            if not isinstance(provider, str) or not provider:
                continue

            host = hosts.get(provider)
            if not isinstance(host, dict):
                raise ValueError(
                    f"service provider {provider!r} for service {service_name!r} "
                    f"has no renderer placement in {enterprise}/{site_name}"
                )

            attach_node = host.get("attach_node")
            if not isinstance(attach_node, str) or not attach_node:
                raise ValueError(
                    f"service provider {provider!r} for service {service_name!r} "
                    f"has invalid attach_node in renderer inventory"
                )

            attach_network = host.get("attach_network")
            if not isinstance(attach_network, str) or not attach_network:
                raise ValueError(
                    f"service provider {provider!r} for service {service_name!r} "
                    f"has invalid attach_network"
                )

            tenant = endpoint_tenants.get(provider)
            if isinstance(tenant, str) and tenant and attach_network != tenant:
                raise ValueError(
                    f"service provider {provider!r} for service {service_name!r} "
                    f"has tenant mismatch in {enterprise}/{site_name}: "
                    f"attach_network={attach_network!r} tenant={tenant!r}"
                )

            resolved_zone = attach_network
            break

        if providers and resolved_zone is None:
            raise ValueError(
                f"service {service_name!r} has providers but none could be resolved "
                f"through renderer inventory in {enterprise}/{site_name}"
            )

        if resolved_zone is not None:
            result[service_name] = resolved_zone

    return result


def load_sites(
    path: str | Path,
    renderer_inventory: Dict[str, Any] | None = None,
) -> Dict[str, SiteModel]:
    solver_path = Path(path)
    data = load_solver(solver_path)

    result: Dict[str, SiteModel] = {}
    solver_meta = dict(data.get("meta", {}) or {})
    renderer_inventory = dict(renderer_inventory or {})

    for enterprise, site_name, site in extract_enterprise_sites(data):
        validate_site_invariants(
            site,
            context={"enterprise": enterprise, "site": site_name},
        )

        assumptions = validate_routing_assumptions(site)

        nodes = _build_nodes(site)
        links = _build_links(site)
        raw_policy = dict(site.get("communicationContract", {}) or {})
        raw_ownership = dict(site.get("ownership", {}) or {})
        validated_inventory = _validate_renderer_inventory_for_site(
            enterprise=enterprise,
            site_name=site_name,
            site=site,
            renderer_inventory=renderer_inventory,
        )
        provider_zone_map = _provider_zone_map(
            enterprise=enterprise,
            site_name=site_name,
            raw_policy=raw_policy,
            raw_ownership=raw_ownership,
            renderer_inventory=validated_inventory,
        )

        key = f"{enterprise}-{site_name}"

        result[key] = SiteModel(
            enterprise=enterprise,
            site=site_name,
            nodes=nodes,
            links=links,
            single_access=assumptions.get("singleAccess", ""),
            domains={},
            raw_policy=raw_policy,
            raw_nat={},
            raw_links=dict(site.get("links", {}) or {}),
            raw_ownership=raw_ownership,
            renderer_inventory=validated_inventory,
            provider_zone_map=provider_zone_map,
            solver_meta=solver_meta,
        )

    return result
