from __future__ import annotations

from typing import Any, Dict
import ipaddress

from clabgen.models import LinkModel, NodeModel
from clabgen.s88.site.interface_model import build_interfaces


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


def string_items(value: Any) -> list[str]:
    items: list[str] = []
    if not isinstance(value, list):
        return items
    for item in value:
        if isinstance(item, str) and item:
            items.append(item)
    return items


def build_nodes(
    site: Dict[str, Any], tenant_prefix_owners: Dict[str, str]
) -> Dict[str, NodeModel]:
    nodes: Dict[str, NodeModel] = {}
    runtime_services: Dict[str, Dict[str, Any]] = {}

    for rt in (site.get("runtimeTargets", {}) or {}).values():
        if not isinstance(rt, dict):
            continue
        logical = rt.get("logicalNode")
        services = rt.get("services")
        logical_name = logical.get("name") if isinstance(logical, dict) else None
        if (
            isinstance(logical_name, str)
            and logical_name
            and isinstance(services, dict)
        ):
            runtime_services[logical_name] = dict(services)

    for unit, node_obj in site.get("nodes", {}).items():
        routing_mode = node_obj.get("routing_mode")
        if not isinstance(routing_mode, str) or not routing_mode:
            raise ValueError(f"node {unit!r} missing explicit routing_mode")
        routing_mode = routing_mode.strip().lower()
        if routing_mode not in {"static", "bgp"}:
            raise ValueError(f"node {unit!r} has invalid routing_mode {routing_mode!r}")

        bgp = node_obj.get("bgp", {})
        loopback4, loopback6 = _loopback_addrs(node_obj)
        nodes[unit] = NodeModel(
            name=unit,
            role=node_obj.get("role", ""),
            routing_domain=node_obj.get("routingDomain", ""),
            interfaces=build_interfaces(site, unit, node_obj, tenant_prefix_owners),
            routing_mode=routing_mode,
            bgp=bgp if isinstance(bgp, dict) else {},
            containers=list(node_obj.get("containers", [])),
            isolated=bool(node_obj.get("isolated", False)),
            services=dict(
                node_obj.get("services", {}) or runtime_services.get(unit, {}) or {}
            ),
            loopback4=loopback4,
            loopback6=loopback6,
            egress_intent=dict(node_obj.get("egressIntent", {}) or {}),
            nat_intent=dict(node_obj.get("natIntent", {}) or {}),
        )

    return nodes


def build_links(site: Dict[str, Any]) -> Dict[str, LinkModel]:
    links: Dict[str, LinkModel] = {}

    for lk, lo in (site.get("links", {}) or {}).items():
        links[lk] = LinkModel(
            name=lk,
            kind=lo.get("kind", "lan"),
            endpoints=lo.get("endpoints", {}),
            bridge=lo.get("bridge") if isinstance(lo.get("bridge"), str) else None,
            host_uplink=dict(lo.get("hostUplink", {}) or {}),
            lane=dict(lo.get("lane", {}) or {}),
            lane_meta=dict(lo.get("laneMeta", {}) or {}),
            uplinks=string_items(lo.get("uplinks", [])),
            overlay=lo.get("overlay") if isinstance(lo.get("overlay"), str) else None,
        )

    return links


def tenant_prefix_owners(site: Dict[str, Any]) -> Dict[str, str]:
    result: Dict[str, str] = {}

    for raw_key, raw_value in dict(site.get("tenantPrefixOwners", {}) or {}).items():
        if (
            not isinstance(raw_key, str)
            or not raw_key
            or not isinstance(raw_value, dict)
        ):
            continue
        dst = raw_value.get("dst")
        net_name = raw_value.get("netName")
        if (
            not isinstance(dst, str)
            or not dst
            or not isinstance(net_name, str)
            or not net_name
        ):
            continue
        try:
            result[str(ipaddress.ip_network(dst, strict=False))] = net_name
        except ValueError:
            continue

    return result
