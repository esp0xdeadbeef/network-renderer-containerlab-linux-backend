from __future__ import annotations

from typing import Dict, Any, List
import copy
import ipaddress
import os

from clabgen.models import NodeModel
from clabgen.s88.EM.base import render as render_em


_ROUTER_ROLES = {"access", "core", "policy", "upstream-selector", "isp"}


def _routing_mode() -> str:
    value = os.environ.get("CLABGEN_ROUTING_MODE", "static").strip().lower()
    if value not in {"static", "bgp"}:
        return "static"
    print("Selected routing mode:", value)
    return value


def _is_host_route(dst: Any) -> bool:
    if not isinstance(dst, str) or not dst:
        return False

    try:
        net = ipaddress.ip_network(dst, strict=False)
    except ValueError:
        return False

    return net.prefixlen == net.max_prefixlen


def _filter_router_bgp_routes(routes: Dict[str, List[Dict[str, Any]]]) -> Dict[str, List[Dict[str, Any]]]:
    filtered = {"ipv4": [], "ipv6": []}

    for family in ("ipv4", "ipv6"):
        family_routes = routes.get(family, [])
        if not isinstance(family_routes, list):
            continue

        for route in family_routes:
            if not isinstance(route, dict):
                continue

            dst = route.get("dst")
            proto = route.get("proto")

            if dst in {"0.0.0.0/0", "::/0"}:
                filtered[family].append(copy.deepcopy(route))
                continue

            if proto == "uplink":
                filtered[family].append(copy.deepcopy(route))
                continue

            if _is_host_route(dst):
                filtered[family].append(copy.deepcopy(route))
                continue

    return filtered


def _routes_for_node(role: str, routing_mode: str, iface_routes: Dict[str, List[Dict[str, Any]]]) -> Dict[str, List[Dict[str, Any]]]:
    if routing_mode != "bgp" or role not in _ROUTER_ROLES:
        return copy.deepcopy(iface_routes)

    return _filter_router_bgp_routes(iface_routes)


def _route_intents_for_node(role: str, routing_mode: str, route_intents: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if routing_mode != "bgp" or role not in _ROUTER_ROLES:
        return list(route_intents)

    return []


def build_node_data(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode()

    node_data: Dict[str, Any] = {
        "name": node_name,
        "role": node.role,
        "routing_mode": routing_mode,
        "interfaces": {
            ifname: {
                "addr4": iface.addr4,
                "addr6": iface.addr6,
                "ll6": iface.ll6,
                "kind": iface.kind,
                "tenant": iface.tenant,
                "overlay": iface.overlay,
                "upstream": iface.upstream,
                "routes": _routes_for_node(node.role, routing_mode, iface.routes),
            }
            for ifname, iface in sorted(node.interfaces.items())
            if ifname in eth_map
        },
        "route_intents": _route_intents_for_node(node.role, routing_mode, node.route_intents),
        "loopback": {
            "ipv4": node.loopback4,
            "ipv6": node.loopback6,
        },
    }

    if extra:
        node_data.update(copy.deepcopy(extra))

    return node_data


def render_linux_node(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode()
    node_data = build_node_data(node_name, node, eth_map, extra=extra)

    exec_cmds = render_em(
        node.role,
        node_name,
        node_data,
        eth_map,
        routing_mode=routing_mode,
        disable_dynamic=(routing_mode != "bgp"),
    )

    return {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "exec": exec_cmds,
    }
