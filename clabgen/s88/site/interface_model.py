from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.models import InterfaceModel


def _dict_list(value: Any, field_name: str) -> List[Dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"{field_name} must be an array")

    result: List[Dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            raise ValueError(f"{field_name} entries must be objects")
        dst = item.get("dst")
        if not isinstance(dst, str) or not dst:
            if isinstance(item.get("sourceFile"), str) and item.get("sourceFile"):
                continue
            raise ValueError(f"{field_name} route missing non-empty 'dst'")
        result.append(dict(item))
    return result


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes_obj = iface.get("routes") or {}
    if not isinstance(routes_obj, dict):
        raise ValueError("interface.routes must be an object")

    return {
        "ipv4": _dict_list(routes_obj.get("ipv4", []), "interface.routes.ipv4")
        + _dict_list(iface.get("uplinkRoutes4", []), "interface.uplinkRoutes4"),
        "ipv6": _dict_list(routes_obj.get("ipv6", []), "interface.routes.ipv6")
        + _dict_list(iface.get("uplinkRoutes6", []), "interface.uplinkRoutes6"),
    }


def _endpoint_fallbacks(
    site: Dict[str, Any], node_name: str, ifname: str, iface: Dict[str, Any]
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
        "upstream": iface.get("upstream")
        or iface.get("uplink")
        or ep.get("upstream")
        or ep.get("uplink")
        or link.get("upstream")
        or link.get("uplink"),
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
    iface_name: str, fb: Dict[str, Any], tenant_prefix_owners: Dict[str, str]
) -> str | None:
    explicit_tenant = fb.get("tenant")
    if isinstance(explicit_tenant, str) and explicit_tenant:
        return explicit_tenant
    if fb.get("kind") != "tenant":
        return None

    for addr in (fb.get("addr4"), fb.get("addr6")):
        network = _network_of(addr)
        tenant = tenant_prefix_owners.get(network or "")
        if isinstance(tenant, str) and tenant:
            return tenant

    raise ValueError(f"tenant interface {iface_name!r} has no tenant mapping")


def build_interfaces(
    site: Dict[str, Any],
    node_name: str,
    node_obj: Dict[str, Any],
    tenant_prefix_owners: Dict[str, str],
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
            tenant=_infer_interface_tenant(link_key, fb, tenant_prefix_owners),
            overlay=fb["overlay"] if isinstance(fb["overlay"], str) else None,
            lane=dict(iface.get("lane", {}) or {}),
            attach_bridge=iface.get("attachBridge")
            if isinstance(iface.get("attachBridge"), str)
            else None,
            host_uplink=dict(iface.get("hostUplink", {}) or {}),
        )

    return interfaces
