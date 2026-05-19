from __future__ import annotations

from typing import Any, Dict, List
import json

from clabgen.models import SiteModel
from clabgen.s88.site.dns_service_tenants import service_tenants_for_definitions


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
    if kind == "external":
        uplinks = obj.get("uplinks")
        if isinstance(uplinks, list):
            result: List[str] = []
            for uplink in uplinks:
                if isinstance(uplink, str) and uplink:
                    result.append(uplink)
            if result:
                return result
        name = obj.get("name")
        return [name] if isinstance(name, str) else []
    if kind == "service":
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
            if not isinstance(endpoint, dict) or endpoint.get("kind") != "external":
                continue
            name = endpoint.get("name")
            if isinstance(name, str) and name:
                result.add(name)
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


def service_tenants(site: SiteModel, contract: Dict[str, Any]) -> Dict[str, List[str]]:
    return service_tenants_for_definitions(site, _service_definitions(contract))
