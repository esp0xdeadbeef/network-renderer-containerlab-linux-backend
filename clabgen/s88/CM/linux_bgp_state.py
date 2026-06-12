from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.s88.CM.linux_addressing import (
    _canon_v6,
    _conflicts_with_wan_peer,
    _normalize_l3_addr,
)

_ROUTER_ROLES = {"access", "core", "policy", "upstream-selector", "isp"}


def _is_bgp_router(role: str) -> bool:
    return role in _ROUTER_ROLES


def _first_router_id(node: Dict[str, Any]) -> str:
    loopback = node.get("loopback", {})
    if isinstance(loopback, dict):
        addr4 = loopback.get("ipv4")
        if isinstance(addr4, str) and addr4:
            try:
                return str(ipaddress.ip_interface(addr4).ip)
            except Exception:
                pass

    candidates: List[str] = []

    for iface in (node.get("interfaces", {}) or {}).values():
        if not isinstance(iface, dict):
            continue

        addr4 = iface.get("addr4")
        if isinstance(addr4, str) and addr4:
            try:
                ipi = ipaddress.ip_interface(_normalize_l3_addr(addr4, iface))
                if ipi.network.prefixlen != 31:
                    candidates.append(str(ipi.ip))
            except Exception:
                pass

    if not candidates:
        raise ValueError(
            "CLAB BGP health check requires at least one candidate router ID "
            "from loopback or non-/31 interface addresses. No candidates found "
            "for node; CPM must provide routerId or valid interface addresses. "
            "CPM_GAP: health check target should come from CPM BGP contract."
        )

    return sorted(candidates)[0]


def _is_service_interface(iface: Dict[str, Any]) -> bool:
    kind = iface.get("kind")
    if kind == "tenant":
        tenant = iface.get("tenant")
        return tenant != "loopback"
    return False


def _collect_bgp_networks(node: Dict[str, Any]) -> tuple[List[str], List[str]]:
    networks4: set[str] = set()
    networks6: set[str] = set()

    loopback = node.get("loopback", {})
    if isinstance(loopback, dict):
        loop4 = loopback.get("ipv4")
        loop6 = loopback.get("ipv6")

        if isinstance(loop4, str) and loop4:
            try:
                networks4.add(str(ipaddress.ip_interface(loop4).network))
            except Exception:
                pass

        if isinstance(loop6, str) and loop6:
            try:
                networks6.add(str(ipaddress.ip_interface(loop6).network))
            except Exception:
                pass

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        if not isinstance(iface, dict):
            continue

        if not _is_service_interface(iface):
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if (
            isinstance(addr4, str)
            and addr4
            and not _conflicts_with_wan_peer(node, ifname, addr4)
        ):
            try:
                networks4.add(
                    str(
                        ipaddress.ip_interface(_normalize_l3_addr(addr4, iface)).network
                    )
                )
            except Exception:
                pass

        if (
            isinstance(addr6, str)
            and addr6
            and not _conflicts_with_wan_peer(node, ifname, addr6)
        ):
            try:
                networks6.add(
                    str(
                        ipaddress.ip_interface(
                            _normalize_l3_addr(_canon_v6(addr6), iface)
                        ).network
                    )
                )
            except Exception:
                pass

    return sorted(networks4), sorted(networks6)


def _peer_ip(cidr: Any) -> str | None:
    if not isinstance(cidr, str) or not cidr:
        return None
    try:
        return str(ipaddress.ip_interface(cidr).ip)
    except Exception:
        return None


def _peer_ip_sort_key(neighbor: Dict[str, Any]) -> str:
    peer_ip = neighbor.get("peer_ip")
    if isinstance(peer_ip, str):
        return peer_ip
    return ""
