from __future__ import annotations

from typing import Any, Dict
import ipaddress

from clabgen.s88.CM.linux_addressing import (
    _canon_v6,
    _conflicts_with_wan_peer,
    _normalize_l3_addr,
    _peer_in_subnet,
)
from clabgen.s88.CM.linux_route_values import _via4, _via6


def _connected_prefixes(node: Dict[str, Any]) -> tuple[set[str], set[str]]:
    connected4: set[str] = set()
    connected6: set[str] = set()

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if (
            isinstance(addr4, str)
            and addr4
            and not _conflicts_with_wan_peer(node, ifname, addr4)
        ):
            try:
                connected4.add(str(ipaddress.ip_interface(addr4).network))
            except Exception:
                pass

        if (
            isinstance(addr6, str)
            and addr6
            and not _conflicts_with_wan_peer(node, ifname, addr6)
        ):
            try:
                connected6.add(str(ipaddress.ip_interface(addr6).network))
            except Exception:
                pass

    loopback = node.get("loopback", {})
    if isinstance(loopback, dict):
        loop4 = loopback.get("ipv4")
        loop6 = loopback.get("ipv6")

        if isinstance(loop4, str) and loop4:
            try:
                connected4.add(str(ipaddress.ip_interface(loop4).network))
            except Exception:
                pass

        if isinstance(loop6, str) and loop6:
            try:
                connected6.add(str(ipaddress.ip_interface(loop6).network))
            except Exception:
                pass

    return connected4, connected6


def _local_ips(node: Dict[str, Any]) -> tuple[set[str], set[str]]:
    local4: set[str] = set()
    local6: set[str] = set()

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if (
            isinstance(addr4, str)
            and addr4
            and not _conflicts_with_wan_peer(node, ifname, addr4)
        ):
            try:
                local4.add(
                    str(ipaddress.ip_interface(_normalize_l3_addr(addr4, iface)).ip)
                )
            except Exception:
                pass

        if (
            isinstance(addr6, str)
            and addr6
            and not _conflicts_with_wan_peer(node, ifname, addr6)
        ):
            try:
                local6.add(
                    str(
                        ipaddress.ip_interface(
                            _normalize_l3_addr(_canon_v6(addr6), iface)
                        ).ip
                    )
                )
            except Exception:
                pass

        if (
            isinstance(ll6, str)
            and ll6
            and not _conflicts_with_wan_peer(node, ifname, ll6)
        ):
            try:
                local6.add(str(ipaddress.ip_interface(_canon_v6(ll6)).ip))
            except Exception:
                pass

    loopback = node.get("loopback", {})
    if isinstance(loopback, dict):
        loop4 = loopback.get("ipv4")
        loop6 = loopback.get("ipv6")

        if isinstance(loop4, str) and loop4:
            try:
                local4.add(str(ipaddress.ip_interface(loop4).ip))
            except Exception:
                pass

        if isinstance(loop6, str) and loop6:
            try:
                local6.add(str(ipaddress.ip_interface(_canon_v6(loop6)).ip))
            except Exception:
                pass

    return local4, local6
