from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.models import SiteModel, NodeModel


def _ownership_endpoint_tenants(site: SiteModel) -> Dict[str, str]:
    endpoints = site.raw_ownership.get("endpoints")
    if not isinstance(endpoints, list):
        return {}
    result: Dict[str, str] = {}
    for endpoint in endpoints:
        if not isinstance(endpoint, dict):
            continue
        name = endpoint.get("name")
        tenant = endpoint.get("tenant")
        if isinstance(name, str) and name and isinstance(tenant, str) and tenant:
            result[name] = tenant
    return result


def _node_dns_service_tenant(node: NodeModel) -> str | None:
    dns = node.services.get("dns") if isinstance(node.services, dict) else None
    if not isinstance(dns, dict):
        return None
    listen = dns.get("listen")
    if not isinstance(listen, list):
        return None
    listen_ips: set[str] = set()
    for value in listen:
        if isinstance(value, str) and value:
            listen_ips.add(value)

    for iface in node.interfaces.values():
        if (
            iface.kind != "tenant"
            or not isinstance(iface.tenant, str)
            or not iface.tenant
        ):
            continue
        for addr in (iface.addr4, iface.addr6):
            if not isinstance(addr, str) or not addr:
                continue
            try:
                ip = str(ipaddress.ip_interface(addr).ip)
            except ValueError:
                continue
            if ip in listen_ips:
                return iface.tenant
    return None


def _dns_service_provider_tenants(site: SiteModel) -> List[str]:
    scored: List[tuple[int, str]] = []
    for node in site.nodes.values():
        tenant = _node_dns_service_tenant(node)
        if tenant is None:
            continue
        dns = node.services.get("dns") if isinstance(node.services, dict) else {}
        allow_from = dns.get("allowFrom") if isinstance(dns, dict) else []
        score = len(allow_from) if isinstance(allow_from, list) else 0
        scored.append((score, tenant))
    if not scored:
        return []
    max_score = scored[0][0]
    for score, _tenant in scored[1:]:
        max_score = max(max_score, score)
    result: set[str] = set()
    for score, tenant in scored:
        if score == max_score:
            result.add(tenant)
    return sorted(result)


def service_tenants_for_definitions(
    site: SiteModel, services: List[Dict[str, Any]]
) -> Dict[str, List[str]]:
    ownership_tenants = _ownership_endpoint_tenants(site)
    dns_provider_tenants = _dns_service_provider_tenants(site)
    result: Dict[str, List[str]] = {}
    for service in services:
        name = service["name"]
        tenants: List[str] = []
        provider_tenants = service.get("providerTenants")
        if isinstance(provider_tenants, list):
            for value in provider_tenants:
                if isinstance(value, str) and value:
                    tenants.append(value)
        providers = service.get("providers")
        if isinstance(providers, list):
            for provider in providers:
                if isinstance(provider, str) and provider in ownership_tenants:
                    tenants.append(ownership_tenants[provider])
        if not tenants and service.get("trafficType") == "dns":
            tenants.extend(dns_provider_tenants)
        result[name] = sorted(set(tenants))
    return result
