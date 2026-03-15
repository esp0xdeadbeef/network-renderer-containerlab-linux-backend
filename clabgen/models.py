from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any


@dataclass
class ControlModuleModel:
    name: str
    logical_id: str
    kind: str
    spec: Dict[str, Any] = field(default_factory=dict)


@dataclass
class EquipmentModuleModel:
    name: str
    kind: str
    spec: Dict[str, Any] = field(default_factory=dict)


@dataclass
class InterfaceModel:
    name: str
    addr4: Optional[str] = None
    addr6: Optional[str] = None
    ll6: Optional[str] = None
    routes: Dict[str, List[Dict[str, Any]]] = field(
        default_factory=lambda: {"ipv4": [], "ipv6": []}
    )
    kind: Optional[str] = None
    upstream: Optional[str] = None
    tenant: Optional[str] = None
    overlay: Optional[str] = None


@dataclass
class NodeModel:
    name: str
    role: str
    routing_domain: str
    interfaces: Dict[str, InterfaceModel]
    containers: List[str] = field(default_factory=list)
    isolated: bool = False
    control_modules: Dict[str, ControlModuleModel] = field(default_factory=dict)
    equipment_modules: Dict[str, EquipmentModuleModel] = field(default_factory=dict)
    route_intents: List[Dict[str, Any]] = field(default_factory=list)
    policy_intents: List[Dict[str, Any]] = field(default_factory=list)
    nat_intents: List[Dict[str, Any]] = field(default_factory=list)
    loopback4: Optional[str] = None
    loopback6: Optional[str] = None


@dataclass
class LinkModel:
    name: str
    kind: str
    endpoints: Dict[str, Dict[str, Any]]


@dataclass
class SiteModel:
    enterprise: str
    site: str
    nodes: Dict[str, NodeModel]
    links: Dict[str, LinkModel]
    single_access: str
    domains: Dict[str, Any]
    raw_policy: Dict[str, Any] = field(default_factory=dict)
    raw_nat: Dict[str, Any] = field(default_factory=dict)
    raw_links: Dict[str, Any] = field(default_factory=dict)
    raw_ownership: Dict[str, Any] = field(default_factory=dict)
    raw_domains: Dict[str, Any] = field(default_factory=dict)
    raw_transport: Dict[str, Any] = field(default_factory=dict)
    renderer_inventory: Dict[str, Any] = field(default_factory=dict)
    provider_zone_map: Dict[str, str] = field(default_factory=dict)
    solver_meta: Dict[str, Any] = field(default_factory=dict)
    bridge_control_modules: Dict[str, ControlModuleModel] = field(default_factory=dict)
    policy_node_name: str = ""
    upstream_selector_node_name: str = ""
    tenant_prefix_owners: Dict[str, Any] = field(default_factory=dict)
    bgp_asn: int = 0
    bgp_sessions: List[Dict[str, Any]] = field(default_factory=list)
