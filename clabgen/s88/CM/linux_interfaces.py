from __future__ import annotations

from typing import Any, Dict, List
import ipaddress

from clabgen.s88.CM.linux_addressing import (
    _canon_v6,
    _conflicts_with_wan_peer,
    _is_virtual_interface,
    _normalize_l3_addr,
    _p2p_peer,
)
from clabgen.s88.CM.linux_shell import _sh


def _render_interfaces(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []
    interfaces = node.get("interfaces", {})

    for logical_if in sorted(interfaces.keys()):
        iface = interfaces[logical_if]
        if logical_if not in eth_map:
            continue

        eth = eth_map[logical_if]

        if _is_virtual_interface(iface):
            cmds.append(
                _sh(
                    f"ip link show {eth} >/dev/null 2>&1 || ip link add {eth} type dummy"
                )
            )

        cmds.append(f"ip link set {eth} up")

    cmds.append("ip link set lo up")

    return cmds


def _render_loopback(node: Dict[str, Any]) -> List[str]:
    cmds: List[str] = []
    loopback = node.get("loopback", {})

    if not isinstance(loopback, dict):
        return cmds

    addr4 = loopback.get("ipv4")
    addr6 = loopback.get("ipv6")

    if isinstance(addr4, str) and addr4:
        cmds.append(f"ip addr replace {addr4} dev lo")

    if isinstance(addr6, str) and addr6:
        cmds.append(f"ip -6 addr replace {_canon_v6(addr6)} dev lo")

    return cmds


def _render_addressing(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if (
            isinstance(addr4, str)
            and addr4
            and not _conflicts_with_wan_peer(node, ifname, addr4)
        ):
            addr4 = _normalize_l3_addr(addr4, iface)
            peer = _p2p_peer(addr4)
            if peer:
                ip = ipaddress.ip_interface(addr4).ip
                prefix = ipaddress.ip_interface(addr4).network.prefixlen
                cmds.append(
                    f"ip addr replace {ip}/{prefix} peer {peer}/{prefix} dev {eth}"
                )
            else:
                cmds.append(f"ip addr replace {addr4} dev {eth}")

        if (
            isinstance(addr6, str)
            and addr6
            and not _conflicts_with_wan_peer(node, ifname, addr6)
        ):
            canon = _canon_v6(addr6)
            canon = _normalize_l3_addr(canon, iface)
            peer = _p2p_peer(canon)
            if peer:
                ip = ipaddress.ip_interface(canon).ip
                prefix = ipaddress.ip_interface(canon).network.prefixlen
                cmds.append(
                    f"ip -6 addr replace {ip}/{prefix} peer {peer}/{prefix} dev {eth}"
                )
            else:
                cmds.append(f"ip -6 addr replace {canon} dev {eth}")

        if (
            isinstance(ll6, str)
            and ll6
            and not _conflicts_with_wan_peer(node, ifname, ll6)
        ):
            cmds.append(f"ip -6 addr replace {_canon_v6(ll6)} dev {eth}")

    cmds.extend(_render_loopback(node))

    return cmds
