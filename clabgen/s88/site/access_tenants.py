from __future__ import annotations

from typing import Any, List, Set
import json

from clabgen.models import SiteModel, NodeModel
from clabgen.s88.site.policy_contract import contract_tenant_names


def is_loopback_tenant_iface(iface: Any) -> bool:
    tenant = getattr(iface, "tenant", None)
    upstream = getattr(iface, "upstream", None)
    name = getattr(iface, "name", None)
    return (
        tenant == "loopback"
        or (isinstance(name, str) and name == "tenant-loopback")
        or (isinstance(upstream, str) and upstream == "tenant-loopback")
    )


def ownership_tenant_names(site: SiteModel) -> List[str]:
    result: set[str] = set()
    prefixes = (site.raw_ownership or {}).get("prefixes", [])
    if not isinstance(prefixes, list):
        return []
    for prefix in prefixes:
        if not isinstance(prefix, dict) or prefix.get("kind") != "tenant":
            continue
        name = prefix.get("name")
        if isinstance(name, str) and name:
            result.add(name)
    return sorted(result)


def access_node_tenants(site: SiteModel, node: NodeModel) -> List[str]:
    tenants: set[str] = set()
    for iface in node.interfaces.values():
        if getattr(iface, "kind", None) != "tenant":
            continue
        if is_loopback_tenant_iface(iface):
            continue
        tenant = getattr(iface, "tenant", None)
        if isinstance(tenant, str) and tenant:
            tenants.add(tenant)
    if tenants:
        return sorted(tenants)

    candidate_tenants = sorted(
        set(contract_tenant_names(dict(site.raw_policy or {})))
        | set(ownership_tenant_names(site))
    )
    if len(candidate_tenants) == 1:
        return candidate_tenants

    raise RuntimeError(
        "tenant cannot be resolved for access node\n"
        + json.dumps(
            {
                "node": node.name,
                "role": node.role,
                "candidate_tenants": candidate_tenants,
                "interfaces": _debug_interfaces(node),
            },
            indent=2,
            default=str,
        )
    )


def _debug_interfaces(node: NodeModel) -> Dict[str, Any]:
    interfaces: Dict[str, Any] = {}
    for name, iface in node.interfaces.items():
        interfaces[name] = getattr(iface, "__dict__", str(iface))
    return interfaces


def domains_external_names(site: SiteModel) -> Set[str]:
    domains = dict(site.raw_domains or site.domains or {})
    externals = domains.get("externals", [])
    if isinstance(externals, dict):
        result: Set[str] = set()
        for name, value in externals.items():
            if isinstance(name, str) and name and value is not None:
                result.add(name)
        return result
    if not isinstance(externals, list):
        return set()

    result: Set[str] = set()
    for item in externals:
        if isinstance(item, str) and item:
            result.add(item)
        elif isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str) and name:
                result.add(name)
    return result


def policy_external_names(site: SiteModel) -> Set[str]:
    policy = site.raw_policy if isinstance(site.raw_policy, dict) else {}
    endpoint_bindings = policy.get("endpointBindings")
    if not isinstance(endpoint_bindings, dict):
        return set()
    externals = endpoint_bindings.get("externals")
    if not isinstance(externals, dict):
        return set()
    names: Set[str] = set()
    for name in externals.keys():
        if isinstance(name, str) and name:
            names.add(name)
    return names
