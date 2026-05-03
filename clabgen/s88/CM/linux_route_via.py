from __future__ import annotations

from typing import Any, Dict
import ipaddress

from clabgen.s88.CM.linux_addressing import _peer_in_subnet
from clabgen.s88.CM.linux_route_state import _local_ips
from clabgen.s88.CM.linux_route_values import _via4, _via6


def _same_subnet(gateway: str | None, iface_addr: str | None) -> bool:
    if not gateway or not iface_addr:
        return False
    try:
        net = ipaddress.ip_interface(iface_addr).network
        gw = ipaddress.ip_address(gateway)
        return gw in net
    except Exception:
        return False


def _route_via_is_local(
    route: Dict[str, Any], family: int, local4: set[str], local6: set[str]
) -> bool:
    if family == 4:
        via = _via4(route)
        return isinstance(via, str) and via in local4
    if family == 6:
        via = _via6(route)
        return isinstance(via, str) and via in local6
    return False


def _effective_via4(
    node: Dict[str, Any], iface: Dict[str, Any], route: Dict[str, Any]
) -> str | None:
    via = _via4(route)
    local4, _ = _local_ips(node)

    if via in local4:
        via = None

    if not via and route.get("proto") == "uplink":
        via = _peer_in_subnet(iface.get("addr4"))

    if via in local4:
        via = _peer_in_subnet(iface.get("addr4"))

    if via in local4:
        return None

    if iface.get("kind") == "overlay":
        return via

    if not _same_subnet(via, iface.get("addr4")):
        return None

    return via


def _effective_via6(
    node: Dict[str, Any], iface: Dict[str, Any], route: Dict[str, Any]
) -> str | None:
    via = _via6(route)
    _, local6 = _local_ips(node)

    if via in local6:
        via = None

    if not via and route.get("proto") == "uplink":
        via = _peer_in_subnet(iface.get("addr6"))

    if via in local6:
        via = _peer_in_subnet(iface.get("addr6"))

    if via in local6:
        return None

    if iface.get("kind") == "overlay":
        return via

    if not _same_subnet(via, iface.get("addr6")):
        return None

    return via
