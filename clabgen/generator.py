from __future__ import annotations

from typing import Dict, List, Set, Any, Tuple
import copy
import hashlib
import ipaddress
import re

from .models import (
    SiteModel,
    NodeModel,
    InterfaceModel,
    ControlModuleModel,
    EquipmentModuleModel,
)
from .linux_router import render_linux_router
from .links import build_eth_index, short_bridge
from .sysctls_catalog import default_sysctls


ROLE_ORDER = [
    "access",
    "policy",
    "upstream-selector",
    "core",
    "wan-peer",
    "isp",
]

_IFNAME_MAX = 15
_SLUG_RE = re.compile(r"[^a-z0-9]+")


def scoped_name(site: SiteModel, unit: str) -> str:
    return f"{site.enterprise}-{site.site}-{unit}"


def _role_rank(role: str) -> int:
    for idx, r in enumerate(ROLE_ORDER):
        if r in role:
            return idx
    return len(ROLE_ORDER)


def _normalize_prefix(prefix: str) -> str:
    net = ipaddress.ip_network(prefix, strict=False)
    return str(net)


def _peer_addr(cidr: str) -> str:
    iface = ipaddress.ip_interface(cidr)
    current = iface.ip

    if isinstance(iface.network, ipaddress.IPv4Network):
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 31:
            candidates = list(iface.network)
    else:
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 127:
            candidates = list(iface.network)

    for cand in candidates:
        if cand != current:
            return f"{cand}/{iface.network.prefixlen}"

    raise ValueError(f"cannot derive peer address from {cidr}")


def _route_lists(iface: InterfaceModel) -> Dict[str, List[Dict[str, Any]]]:
    return {
        "ipv4": list((iface.routes or {}).get("ipv4", [])),
        "ipv6": list((iface.routes or {}).get("ipv6", [])),
    }


def _slug(value: str) -> str:
    value = value.lower().strip()
    value = _SLUG_RE.sub("-", value).strip("-")
    return value or "x"


def _stable_ifname(prefix: str, logical_id: str, maxlen: int = _IFNAME_MAX) -> str:
    base = f"{prefix}{_slug(logical_id)}"
    if len(base) <= maxlen:
        return base

    digest = hashlib.blake2s(logical_id.encode("utf-8"), digest_size=2).hexdigest()
    keep = maxlen - 1 - len(digest)
    return f"{base[:keep]}-{digest}"


def _augment_site(site: SiteModel) -> SiteModel:
    site = copy.deepcopy(site)

    for link_name, link in list(site.links.items()):
        if link.kind != "wan":
            continue

        eps = sorted(link.endpoints.keys())
        if len(eps) != 1:
            continue

        unit = eps[0]
        ep = link.endpoints[unit]
        uplink = ep.get("uplink") or link_name
        peer_name = f"wan-peer-{uplink}"

        if peer_name not in site.nodes:
            site.nodes[peer_name] = NodeModel(
                name=peer_name,
                role="wan-peer",
                routing_domain="",
                interfaces={},
                containers=[],
            )

        peer_ep: Dict[str, Any] = {
            "node": peer_name,
            "interface": link_name,
        }

        if ep.get("addr4"):
            peer_ep["addr4"] = _peer_addr(ep["addr4"])
        if ep.get("addr6"):
            peer_ep["addr6"] = _peer_addr(ep["addr6"])

        link.endpoints[peer_name] = peer_ep

        peer_routes4: List[Dict[str, Any]] = []
        peer_routes6: List[Dict[str, Any]] = []

        for node_name, node in site.nodes.items():
            if node_name == peer_name:
                continue

            for iface in node.interfaces.values():
                if iface.kind == "wan":
                    continue

                routes = _route_lists(iface)

                for r in routes["ipv4"]:
                    if r.get("proto") != "connected":
                        continue
                    dst = r.get("dst") or r.get("to")
                    if dst and ep.get("addr4"):
                        peer_routes4.append(
                            {
                                "dst": _normalize_prefix(dst),
                                "via4": ep["addr4"].split("/")[0],
                            }
                        )

                for r in routes["ipv6"]:
                    if r.get("proto") != "connected":
                        continue
                    dst = r.get("dst") or r.get("to")
                    if dst and ep.get("addr6"):
                        peer_routes6.append(
                            {
                                "dst": _normalize_prefix(dst),
                                "via6": ep["addr6"].split("/")[0],
                            }
                        )

        site.nodes[peer_name].interfaces[link_name] = InterfaceModel(
            name=link_name,
            addr4=peer_ep.get("addr4"),
            addr6=peer_ep.get("addr6"),
            ll6=None,
            kind="wan",
            upstream=uplink,
            routes={
                "ipv4": peer_routes4,
                "ipv6": peer_routes6,
            },
        )

    return site


def _build_route_intents(site: SiteModel) -> None:
    for unit, node in site.nodes.items():
        intents: List[Dict[str, Any]] = []

        for cm in node.control_modules.values():
            if cm.kind != "adapter":
                continue

            routes = cm.spec.get("routes", {})
            for family in ("ipv4", "ipv6"):
                for r in list(routes.get(family, [])):
                    intents.append(
                        {
                            "family": family,
                            "dst": r.get("dst") or r.get("to"),
                            "proto": r.get("proto"),
                            "via4": r.get("via4") or r.get("via"),
                            "via6": r.get("via6") or r.get("via"),
                            "dev": cm.spec.get("platform_name", cm.name),
                            "logical_dev": cm.logical_id,
                            "unit": unit,
                        }
                    )

        node.route_intents = intents
        node.equipment_modules["routing"] = EquipmentModuleModel(
            name="routing",
            kind="RoutingEM",
            spec={"routeCount": len(intents)},
        )


def _build_bridge_control_modules(site: SiteModel, eth_index: Dict[str, Dict[str, int]]) -> None:
    bridge_name_owner: Dict[str, str] = {}
    bridge_cms: Dict[str, ControlModuleModel] = {}

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        eps = sorted(link.endpoints.keys())

        if len(eps) != 2:
            raise ValueError(
                f"link '{link_name}' did not project symmetrically: expected 2 endpoints, got {len(eps)}"
            )

        bridge_name = short_bridge(f"{site.enterprise}-{site.site}-{link_name}")
        logical_id = f"bridge:{site.enterprise}:{site.site}:{link_name}"

        owner = bridge_name_owner.get(bridge_name)
        if owner is not None and owner != logical_id:
            raise ValueError(
                f"bridge ifname collision: {bridge_name!r} for {owner!r} and {logical_id!r}"
            )
        bridge_name_owner[bridge_name] = logical_id

        endpoints: List[str] = []
        ports: List[Dict[str, Any]] = []

        for unit in eps:
            if unit not in eth_index or link_name not in eth_index[unit]:
                raise ValueError(
                    f"missing interface projection for node '{unit}' link '{link_name}'"
                )

            full_name = scoped_name(site, unit)
            eth_num = eth_index[unit][link_name]
            port_name = f"eth{eth_num}"

            endpoints.append(f"{full_name}:{port_name}")
            ports.append(
                {
                    "unit": unit,
                    "node": full_name,
                    "dev": port_name,
                    "logical_iface": link_name,
                }
            )

        bridge_cms[logical_id] = ControlModuleModel(
            name=bridge_name,
            logical_id=logical_id,
            kind="bridge",
            spec={
                "site": site.site,
                "enterprise": site.enterprise,
                "link_id": link_name,
                "link_kind": link.kind,
                "ports": ports,
                "endpoints": endpoints,
                "wire_plan": {
                    "mode": "bridge",
                    "bridge": bridge_name,
                },
            },
        )

    tenant_groups: Dict[str, List[Tuple[str, int]]] = {}
    for unit, node in site.nodes.items():
        for ifname, iface in node.interfaces.items():
            if iface.kind != "tenant":
                continue
            if unit not in eth_index or ifname not in eth_index[unit]:
                continue
            tenant_groups.setdefault(ifname, []).append((scoped_name(site, unit), eth_index[unit][ifname]))

    for tenant_name in sorted(tenant_groups.keys()):
        bridge_name = short_bridge(f"{site.enterprise}-{site.site}-tenant-{tenant_name}")
        logical_id = f"bridge:{site.enterprise}:{site.site}:tenant:{tenant_name}"

        owner = bridge_name_owner.get(bridge_name)
        if owner is not None and owner != logical_id:
            raise ValueError(
                f"bridge ifname collision: {bridge_name!r} for {owner!r} and {logical_id!r}"
            )
        bridge_name_owner[bridge_name] = logical_id

        endpoints = [f"{node}:eth{eth}" for node, eth in tenant_groups[tenant_name]]
        ports = [
            {
                "node": node,
                "dev": f"eth{eth}",
                "logical_iface": tenant_name,
            }
            for node, eth in tenant_groups[tenant_name]
        ]

        host_port = None
        if len(endpoints) == 1:
            host_port = _stable_ifname("veth-", bridge_name)
            endpoints.append(f"host:{host_port}")

        bridge_cms[logical_id] = ControlModuleModel(
            name=bridge_name,
            logical_id=logical_id,
            kind="bridge",
            spec={
                "site": site.site,
                "enterprise": site.enterprise,
                "link_id": tenant_name,
                "link_kind": "tenant",
                "ports": ports,
                "host_port": host_port,
                "endpoints": endpoints,
                "wire_plan": {
                    "mode": "bridge",
                    "bridge": bridge_name,
                },
            },
        )

    site.bridge_control_modules = bridge_cms


def _build_unit_control_modules(site: SiteModel, eth_index: Dict[str, Dict[str, int]]) -> None:
    for unit, node in site.nodes.items():
        cm_by_logical: Dict[str, ControlModuleModel] = {}
        cm_name_owner: Dict[str, str] = {}

        for logical_iface, iface in sorted(node.interfaces.items()):
            if unit not in eth_index or logical_iface not in eth_index[unit]:
                continue

            platform_name = f"eth{eth_index[unit][logical_iface]}"
            logical_id = f"adapter:{site.enterprise}:{site.site}:{unit}:{logical_iface}"

            owner = cm_name_owner.get(platform_name)
            if owner is not None and owner != logical_id:
                raise ValueError(
                    f"adapter ifname collision on unit {unit!r}: {platform_name!r} for {owner!r} and {logical_id!r}"
                )
            cm_name_owner[platform_name] = logical_id

            cm_by_logical[logical_id] = ControlModuleModel(
                name=platform_name,
                logical_id=logical_id,
                kind="adapter",
                spec={
                    "platform_name": platform_name,
                    "logical_iface": logical_iface,
                    "node": unit,
                    "kind": iface.kind,
                    "addr4": iface.addr4,
                    "addr6": iface.addr6,
                    "ll6": iface.ll6,
                    "routes": {
                        "ipv4": list((iface.routes or {}).get("ipv4", [])),
                        "ipv6": list((iface.routes or {}).get("ipv6", [])),
                    },
                    "upstream": iface.upstream,
                },
            )

        node.control_modules = cm_by_logical


def _build_s88_inventory(site: SiteModel) -> Tuple[SiteModel, Dict[str, Dict[str, int]]]:
    site = copy.deepcopy(site)
    eth_index = build_eth_index(site)
    _build_unit_control_modules(site, eth_index)
    _build_bridge_control_modules(site, eth_index)
    _build_route_intents(site)
    return site, eth_index


def generate_topology(site: SiteModel) -> Dict[str, Any]:
    site = _augment_site(copy.deepcopy(site))
    site, eth_index = _build_s88_inventory(site)

    defaults = {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "sysctls": default_sysctls(),
    }

    if not site.nodes:
        return {
            "name": f"{site.enterprise}-{site.site}",
            "topology": {
                "defaults": defaults,
                "nodes": {},
                "links": [],
            },
            "bridges": [],
            "bridge_control_modules": {},
            "solver_meta": dict(site.solver_meta),
        }

    rendered_nodes: Dict[str, Dict[str, Any]] = {}
    rendered_links: List[Dict[str, Any]] = []
    bridges: Set[str] = set()

    sorted_units = sorted(
        site.nodes.items(),
        key=lambda kv: (_role_rank(kv[1].role or ""), kv[0]),
    )

    for unit, node in sorted_units:
        full_name = scoped_name(site, unit)

        node_dict = {
            "name": unit,
            "role": node.role or "",
            "interfaces": {
                ifname: {
                    "addr4": iface.addr4,
                    "addr6": iface.addr6,
                    "ll6": iface.ll6,
                    "kind": iface.kind,
                    "upstream": iface.upstream,
                    "routes": {
                        "ipv4": list((iface.routes or {}).get("ipv4", [])),
                        "ipv6": list((iface.routes or {}).get("ipv6", [])),
                    },
                }
                for ifname, iface in node.interfaces.items()
            },
            "route_intents": list(node.route_intents),
        }

        rendered = render_linux_router(node_dict, eth_index.get(unit, {}))

        node_def: Dict[str, Any] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
        }

        if rendered.get("exec"):
            node_def["exec"] = [str(cmd) for cmd in rendered["exec"]]

        rendered_nodes[full_name] = node_def

    bridge_control_modules: Dict[str, Dict[str, Any]] = {}
    for logical_id in sorted(site.bridge_control_modules.keys()):
        cm = site.bridge_control_modules[logical_id]
        bridge_name = cm.name
        bridges.add(bridge_name)
        rendered_links.append(
            {
                "endpoints": list(cm.spec.get("endpoints", [])),
                "labels": {
                    "clab.link.type": "bridge",
                    "clab.link.bridge": bridge_name,
                },
            }
        )
        bridge_control_modules[logical_id] = {
            "name": cm.name,
            "logical_id": cm.logical_id,
            "kind": cm.kind,
            "spec": copy.deepcopy(cm.spec),
        }

    return {
        "name": f"{site.enterprise}-{site.site}",
        "topology": {
            "defaults": defaults,
            "nodes": rendered_nodes,
            "links": rendered_links,
        },
        "bridges": sorted(list(bridges)),
        "bridge_control_modules": bridge_control_modules,
        "solver_meta": dict(site.solver_meta),
    }
