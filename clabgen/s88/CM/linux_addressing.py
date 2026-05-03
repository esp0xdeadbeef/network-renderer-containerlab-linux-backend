from __future__ import annotations

from typing import Any, Dict
import ipaddress


def _is_virtual_interface(iface: Dict[str, Any]) -> bool:
    return bool(
        iface.get("virtual") is True
        or iface.get("logical") is True
        or iface.get("type") == "logical"
        or iface.get("carrier") == "logical"
    )


def _canon_v6(addr: str) -> str:
    try:
        return str(ipaddress.IPv6Interface(addr))
    except Exception:
        return addr


def _is_network_address(addr: str) -> bool:
    try:
        iface = ipaddress.ip_interface(addr)
    except Exception:
        return False
    return iface.ip == iface.network.network_address


def _first_usable_host(addr: str) -> str:
    iface = ipaddress.ip_interface(addr)
    net = iface.network

    if isinstance(net, ipaddress.IPv4Network):
        if net.prefixlen >= 31:
            return str(iface)
        for host_address in net.hosts():
            return f"{host_address}/{net.prefixlen}"
        return str(iface)

    if net.prefixlen >= 127:
        return str(iface)

    for host_address in net.hosts():
        return f"{host_address}/{net.prefixlen}"
    return str(iface)


def _normalize_l3_addr(addr: str, iface: Dict[str, Any]) -> str:
    if not isinstance(addr, str) or not addr:
        return addr

    if iface.get("kind") == "tenant" and _is_network_address(addr):
        return _first_usable_host(addr)

    return addr


def _p2p_peer(addr: str) -> str | None:
    try:
        iface = ipaddress.ip_interface(addr)
        net = iface.network
        ip = iface.ip

        if isinstance(net, ipaddress.IPv4Network) and net.prefixlen == 31:
            first_address, second_address = list(net)
            peer = second_address if ip == first_address else first_address
            return str(peer)

        if isinstance(net, ipaddress.IPv6Network) and net.prefixlen == 127:
            first_address, second_address = list(net)
            peer = second_address if ip == first_address else first_address
            return str(peer)

    except Exception:
        return None

    return None


def _addr_ip(addr: str | None) -> str | None:
    if not isinstance(addr, str) or not addr:
        return None
    try:
        return str(ipaddress.ip_interface(addr).ip)
    except Exception:
        return None


def _peer_in_subnet(cidr: str | None) -> str | None:
    if not isinstance(cidr, str) or not cidr:
        return None

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
            return str(cand)

    return None


def _conflicts_with_wan_peer(
    node: Dict[str, Any],
    ifname: str,
    addr: str | None,
) -> bool:
    ip = _addr_ip(addr)
    if ip is None:
        return False

    interfaces = node.get("interfaces", {}) or {}

    for other_ifname, other_iface in interfaces.items():
        if other_ifname == ifname:
            continue
        if not isinstance(other_iface, dict):
            continue
        if other_iface.get("kind") != "wan":
            continue

        peer4 = _peer_in_subnet(other_iface.get("addr4"))
        peer6 = _peer_in_subnet(other_iface.get("addr6"))

        if ip == peer4 or ip == peer6:
            return True

    return False
