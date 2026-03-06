from __future__ import annotations

from typing import Dict, Any, List
import ipaddress


def _canon_v6(addr: str) -> str:
    try:
        return str(ipaddress.IPv6Interface(addr))
    except Exception:
        return addr


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
            cmds.append(f"ip addr replace {addr4} dev eth{eth}")

        if isinstance(addr6, str) and addr6:
            cmds.append(f"ip -6 addr replace {_canon_v6(addr6)} dev eth{eth}")

        if isinstance(ll6, str) and ll6:
            cmds.append(f"ip -6 addr replace {_canon_v6(ll6)} dev eth{eth}")

    return cmds
