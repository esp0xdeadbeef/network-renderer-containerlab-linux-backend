from __future__ import annotations

from typing import Dict, Any, List
import ipaddress


def _canon_v6(addr: str) -> str:
    try:
        return str(ipaddress.IPv6Interface(addr))
    except Exception:
        return addr


def _p2p_peer(addr: str) -> str | None:
    try:
        iface = ipaddress.ip_interface(addr)
        net = iface.network
        ip = iface.ip

        if isinstance(net, ipaddress.IPv4Network) and net.prefixlen == 31:
            a, b = list(net.hosts()) if net.num_addresses > 2 else list(net)
            peer = b if ip == a else a
            return str(peer)

        if isinstance(net, ipaddress.IPv6Network) and net.prefixlen == 127:
            a, b = list(net.hosts()) if net.num_addresses > 2 else list(net)
            peer = b if ip == a else a
            return str(peer)

    except Exception:
        return None

    return None


def render_addressing(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if isinstance(addr4, str) and addr4:
            peer = _p2p_peer(addr4)
            if peer:
                ip = ipaddress.ip_interface(addr4).ip
                prefix = ipaddress.ip_interface(addr4).network.prefixlen
                cmds.append(f"ip addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}")
            else:
                cmds.append(f"ip addr replace {addr4} dev eth{eth}")

        if isinstance(addr6, str) and addr6:
            canon = _canon_v6(addr6)
            peer = _p2p_peer(canon)
            if peer:
                ip = ipaddress.ip_interface(canon).ip
                prefix = ipaddress.ip_interface(canon).network.prefixlen
                cmds.append(f"ip -6 addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}")
            else:
                cmds.append(f"ip -6 addr replace {canon} dev eth{eth}")

        if isinstance(ll6, str) and ll6:
            cmds.append(f"ip -6 addr replace {_canon_v6(ll6)} dev eth{eth}")

    return cmds
