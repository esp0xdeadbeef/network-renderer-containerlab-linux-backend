from __future__ import annotations

from typing import Dict, List, Any
from pathlib import Path
import hashlib
import ipaddress

from clabgen.solver import (
    load_solver,
    extract_enterprise_sites,
    validate_site_invariants,
    validate_routing_assumptions,
)

from clabgen.models import SiteModel, NodeModel, InterfaceModel, LinkModel


def _dict_list(value: Any, field_name: str) -> List[Dict[str, Any]]:
    if value is None:
        return []

    if not isinstance(value, list):
        raise ValueError(f"{field_name} must be an array")

    result: List[Dict[str, Any]] = []

    for item in value:
        if not isinstance(item, dict):
            raise ValueError(f"{field_name} entries must be objects")

        if "dst" not in item:
            raise ValueError(f"{field_name} route missing 'dst'")

        dst = item["dst"]
        if not isinstance(dst, str) or not dst:
            raise ValueError(f"{field_name} route 'dst' must be a non-empty string")

        result.append(dict(item))

    return result


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes_obj = iface.get("routes")
    if routes_obj is None:
        routes_obj = {}

    if not isinstance(routes_obj, dict):
        raise ValueError("interface.routes must be an object")

    ipv4 = _dict_list(routes_obj.get("ipv4", []), "interface.routes.ipv4")
    ipv6 = _dict_list(routes_obj.get("ipv6", []), "interface.routes.ipv6")

    uplink4 = _dict_list(iface.get("uplinkRoutes4", []), "interface.uplinkRoutes4")
    uplink6 = _dict_list(iface.get("uplinkRoutes6", []), "interface.uplinkRoutes6")

    return {
        "ipv4": ipv4 + uplink4,
        "ipv6": ipv6 + uplink6,
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
        "overlay": iface.get("overlay") or ep.get("overlay") or link.get("overlay"),
        "upstream": (
            iface.get("upstream")
            or iface.get("uplink")
            or ep.get("upstream")
            or ep.get("uplink")
            or link.get("upstream")
            or link.get("uplink")
        ),
        "tenant": iface.get("tenant") or ep.get("tenant") or link.get("tenant"),
    }


def _network_of(addr: Any) -> str | None:
    if not isinstance(addr, str) or not addr:
        return None

    try:
        return str(ipaddress.ip_interface(addr).network)
    except ValueError:
        return None


def _infer_interface_tenant(
    *,
    iface_name: str,
    fb: Dict[str, Any],
    tenant_prefix_owners: Dict[str, str],
) -> str | None:
    explicit_tenant = fb.get("tenant")
    if isinstance(explicit_tenant, str) and explicit_tenant:
        return explicit_tenant

    kind = fb.get("kind")
    if kind != "tenant":
        return None

    for addr in (fb.get("addr4"), fb.get("addr6")):
        network = _network_of(addr)
        if network is None:
            continue

        tenant = tenant_prefix_owners.get(network)
        if isinstance(tenant, str) and tenant:
            return tenant

    raise ValueError(
        f"tenant interface {iface_name!r} has no tenant mapping from solver prefix ownership"
    )


def _build_interfaces(
    site: Dict[str, Any],
    node_name: str,
    node_obj: Dict[str, Any],
    tenant_prefix_owners: Dict[str, str],
) -> Dict[str, InterfaceModel]:
    interfaces: Dict[str, InterfaceModel] = {}

    for link_key, iface in node_obj.get("interfaces", {}).items():
        fb = _endpoint_fallbacks(site, node_name, link_key, iface)

        tenant = _infer_interface_tenant(
            iface_name=link_key,
            fb=fb,
            tenant_prefix_owners=tenant_prefix_owners,
        )

        interfaces[link_key] = InterfaceModel(
            name=link_key,
            addr4=fb["addr4"],
            addr6=fb["addr6"],
            ll6=fb["ll6"],
            routes=_route_lists(iface),
            kind=fb["kind"],
            upstream=fb["upstream"],
            tenant=tenant,
            overlay=fb["overlay"] if isinstance(fb["overlay"], str) else None,
        )

    return interfaces


def _loopback_addrs(node_obj: Dict[str, Any]) -> tuple[str | None, str | None]:
    loopback = node_obj.get("loopback", {})
    if not isinstance(loopback, dict):
        return None, None

    addr4 = loopback.get("ipv4")
    addr6 = loopback.get("ipv6")

    return (
        addr4 if isinstance(addr4, str) and addr4 else None,
        addr6 if isinstance(addr6, str) and addr6 else None,
    )


def _build_nodes(
    site: Dict[str, Any],
    tenant_prefix_owners: Dict[str, str],
) -> Dict[str, NodeModel]:
    nodes: Dict[str, NodeModel] = {}

    for unit, node_obj in site.get("nodes", {}).items():
        interfaces = _build_interfaces(site, unit, node_obj, tenant_prefix_owners)
        loopback4, loopback6 = _loopback_addrs(node_obj)

        nodes[unit] = NodeModel(
            name=unit,
            role=node_obj.get("role", ""),
            routing_domain=node_obj.get("routingDomain", ""),
            interfaces=interfaces,
            containers=list(node_obj.get("containers", [])),
            isolated=bool(node_obj.get("isolated", False)),
            loopback4=loopback4,
            loopback6=loopback6,
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


def _tenant_prefix_owners(site: Dict[str, Any]) -> Dict[str, str]:
    raw = dict(site.get("tenantPrefixOwners", {}) or {})
    result: Dict[str, str] = {}

    for raw_key, raw_value in raw.items():
        if not isinstance(raw_key, str) or not raw_key:
            continue

        if not isinstance(raw_value, dict):
            continue

        dst = raw_value.get("dst")
        net_name = raw_value.get("netName")

        if not isinstance(dst, str) or not dst:
            continue
        if not isinstance(net_name, str) or not net_name:
            continue

        try:
            normalized = str(ipaddress.ip_network(dst, strict=False))
        except ValueError:
            continue

        result[normalized] = net_name

    return result


def _site_asn(enterprise: str, site_name: str) -> int:
    digest = hashlib.blake2s(
        f"{enterprise}:{site_name}".encode(),
        digest_size=4,
    ).digest()
    value = int.from_bytes(digest, byteorder="big", signed=False)
    return 4_200_000_000 + (value % 100_000_000)


def _build_bgp_sessions(site: Dict[str, Any]) -> List[Dict[str, Any]]:
    nodes = dict(site.get("nodes", {}) or {})
    policy = site.get("policyNodeName")

    if not isinstance(policy, str) or not policy:
        return []

    policy_node = nodes.get(policy)
    if not isinstance(policy_node, dict):
        return []

    sessions: List[Dict[str, Any]] = []

    for node_name, node_obj in sorted(nodes.items()):
        if node_name == policy:
            continue
        if not isinstance(node_obj, dict):
            continue

        role = node_obj.get("role")
        if role not in {"access", "core", "upstream-selector"}:
            continue

        sessions.append(
            {
                "a": node_name,
                "b": policy,
                "rr": policy,
            }
        )

    deduped: List[Dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()

    for session in sessions:
        a = str(session["a"])
        b = str(session["b"])
        rr = str(session["rr"])
        key = (a, b, rr)
        if a == b or key in seen:
            continue
        seen.add(key)
        deduped.append(session)

    return deduped


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
        tenant_prefix_owners = _tenant_prefix_owners(site)

        nodes = _build_nodes(site, tenant_prefix_owners)
        links = _build_links(site)

        raw_policy = dict(site.get("communicationContract", {}) or {})
        raw_ownership = dict(site.get("ownership", {}) or {})
        raw_domains = dict(site.get("domains", {}) or {})
        raw_transport = dict(site.get("transport", {}) or {})
        bgp_asn = _site_asn(enterprise, site_name)
        bgp_sessions = _build_bgp_sessions(site)

        key = f"{enterprise}-{site_name}"

        result[key] = SiteModel(
            enterprise=enterprise,
            site=site_name,
            nodes=nodes,
            links=links,
            single_access=assumptions.get("singleAccess", ""),
            domains=raw_domains,
            raw_policy=raw_policy,
            raw_nat={},
            raw_links=dict(site.get("links", {}) or {}),
            raw_ownership=raw_ownership,
            raw_domains=raw_domains,
            raw_transport=raw_transport,
            renderer_inventory=renderer_inventory,
            provider_zone_map={},
            solver_meta=solver_meta,
            policy_node_name=str(site.get("policyNodeName", "") or ""),
            upstream_selector_node_name=str(site.get("upstreamSelectorNodeName", "") or ""),
            tenant_prefix_owners=tenant_prefix_owners,
            bgp_asn=bgp_asn,
            bgp_sessions=bgp_sessions,
        )

    return result
