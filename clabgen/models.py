from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any


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


@dataclass
class NodeModel:
    name: str
    role: str
    routing_domain: str
    interfaces: Dict[str, InterfaceModel]
    containers: List[str] = field(default_factory=list)


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
