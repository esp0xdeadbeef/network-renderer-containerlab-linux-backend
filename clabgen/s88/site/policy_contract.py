from __future__ import annotations

from typing import Any, Dict, List
import ipaddress
import json

from clabgen.models import SiteModel, NodeModel


def members(obj: Any) -> List[str]:
    if isinstance(obj, str):
        return [obj]
    if isinstance(obj, list):
        result: List[str] = []
        for item in obj:
            result.extend(members(item))
        return result
    if not isinstance(obj, dict):
        return []

    kind = obj.get("kind")
    if kind in {"tenant", "tenant-set"}:
        raw_members = obj.get("members")
        if isinstance(raw_members, list):
            result: List[str] = []
            for member in raw_members:
                if isinstance(member, str):
                    result.append(str(member))
            return result
        name = obj.get("name")
        return [name] if isinstance(name, str) else []
    if kind in {"external", "service"}:
        name = obj.get("name")
        return [name] if isinstance(name, str) else []
    return []


def endpoint_members(obj: Any, service_tenants: Dict[str, List[str]]) -> List[str]:
    if isinstance(obj, str) and obj in service_tenants:
        return list(service_tenants[obj])
    if isinstance(obj, dict) and obj.get("kind") == "service":
        name = obj.get("name")
        if isinstance(name, str) and name:
            return list(service_tenants.get(name, []))
    return members(obj)


def relation_objects(contract: Dict[str, Any]) -> List[Dict[str, Any]]:
    relations = contract.get("allowedRelations") or contract.get("relations")
    if not isinstance(relations, list):
        raise RuntimeError(
            "communicationContract.allowedRelations must be array\n"
            + json.dumps(contract, indent=2, default=str)
        )
    result: List[Dict[str, Any]] = []
    for relation in relations:
        if isinstance(relation, dict):
            result.append(relation)
    return result


def contract_tenant_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()
    for relation in relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if isinstance(endpoint, dict) and endpoint.get("kind") in {
                "tenant",
                "tenant-set",
            }:
                result.update(members(endpoint))
    return sorted(result)


def contract_external_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()
    for relation in relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if isinstance(endpoint, dict) and endpoint.get("kind") == "external":
                result.update(members(endpoint))
    return sorted(result)


def _service_definitions(contract: Dict[str, Any]) -> List[Dict[str, Any]]:
    services = contract.get("services")
    if not isinstance(services, list):
        return []
    result: List[Dict[str, Any]] = []
    for service in services:
        if (
            isinstance(service, dict)
            and isinstance(service.get("name"), str)
            and service.get("name")
        ):
            result.append(service)
    return result


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
        if score > max_score:
            max_score = score
    result: set[str] = set()
    for score, tenant in scored:
        if score == max_score:
            result.add(tenant)
    return sorted(result)


def service_tenants(site: SiteModel, contract: Dict[str, Any]) -> Dict[str, List[str]]:
    ownership_tenants = _ownership_endpoint_tenants(site)
    dns_provider_tenants = _dns_service_provider_tenants(site)
    result: Dict[str, List[str]] = {}
    for service in _service_definitions(contract):
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
