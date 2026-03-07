# ./clabgen/node_roles.py
from __future__ import annotations

from typing import Dict, Any


class PodNode:
    role: str = "generic"

    def __init__(self, node: Dict[str, Any]) -> None:
        self.node = node

    def interfaces(self) -> Dict[str, Any]:
        return self.node.get("interfaces", {}) or {}

    def management_interface(self) -> str | None:
        for name, iface in self.interfaces().items():
            if iface.get("mgmt") is True:
                return name
        return None

    def fabric_interfaces(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for name, iface in self.interfaces().items():
            if iface.get("fabric") is True:
                result[name] = iface
        return result

    def access_interfaces(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for name, iface in self.interfaces().items():
            if iface.get("access") is True:
                result[name] = iface
        return result


class AccessNode(PodNode):
    role = "access"

    def access_interfaces(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for name, iface in self.interfaces().items():
            if iface.get("access") or name.startswith("eth2"):
                result[name] = iface
        return result


class CoreNode(PodNode):
    role = "core"

    def fabric_interfaces(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for name, iface in self.interfaces().items():
            if iface.get("fabric") or name.startswith("eth1"):
                result[name] = iface
        return result


class PolicyNode(PodNode):
    role = "policy"

    def fabric_interfaces(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for name, iface in self.interfaces().items():
            if iface.get("fabric") or name.startswith("eth"):
                result[name] = iface
        return result


ROLE_CLASS_MAP = {
    "s-router-access-client": AccessNode,
    "s-router-access-admin": AccessNode,
    "s-router-access-mgmt": AccessNode,
    "s-router-core-wan": CoreNode,
    "s-router-core-nebula": CoreNode,
    "s-router-policy": PolicyNode,
}


def build_node_role(node: Dict[str, Any]) -> PodNode:
    role = node.get("role")
    cls = ROLE_CLASS_MAP.get(role, PodNode)
    return cls(node)
