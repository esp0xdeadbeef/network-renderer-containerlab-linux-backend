# ./clabgen/s88/CM/nat.py
from __future__ import annotations

from typing import List, Dict, Any


def render(input_data: Dict[str, Any]) -> List[str]:
    ipv4 = bool(input_data.get("ipv4", False))
    ipv6 = bool(input_data.get("ipv6", False))
    masquerade_interfaces = input_data.get("masqueradeInterfaces", [])
    if not isinstance(masquerade_interfaces, list):
        masquerade_interfaces = []

    routes_v4 = input_data.get("routes_v4", [])
    routes_v6 = input_data.get("routes_v6", [])

    cmds: List[str] = [
        "sysctl -w net.ipv4.ip_forward=1",
        "sysctl -w net.ipv6.conf.all.forwarding=1",
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
    ]

    saddr4 = input_data.get("saddr4", [])
    if not isinstance(saddr4, list):
        saddr4 = []
    saddr6 = input_data.get("saddr6", [])
    if not isinstance(saddr6, list):
        saddr6 = []

    if ipv4:
        # Table creation is idempotent; chain uses same priority as firewall_wan.py
        # to avoid conflicting chain specs (duplicate chain add is a benign error).
        cmds.extend([
            "nft add table ip nat",
            "nft 'add chain ip nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
        ])
        if saddr4 and masquerade_interfaces:
            srcset = ",".join(saddr4)
            for iface in masquerade_interfaces:
                cmds.append(f'nft add rule ip nat postrouting ip saddr {{ {srcset} }} oifname "{iface}" masquerade')

    if ipv6:
        cmds.extend([
            "nft add table ip6 nat",
            "nft 'add chain ip6 nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
        ])
        if saddr6 and masquerade_interfaces:
            srcset6 = ",".join(saddr6)
            for iface in masquerade_interfaces:
                cmds.append(f'nft add rule ip6 nat postrouting ip6 saddr {{ {srcset6} }} oifname "{iface}" masquerade')

    for route in routes_v4:
        dst = route.get("dst")
        via = route.get("via4")
        if isinstance(dst, str) and isinstance(via, str):
            cmds.append(f"ip route replace {dst} via {via}")

    for route in routes_v6:
        dst = route.get("dst")
        via = route.get("via6")
        if isinstance(dst, str) and isinstance(via, str):
            cmds.append(f"ip -6 route replace {dst} via {via}")

    cmds.extend(
        [
            "ip route flush cache",
            "ip -6 route flush cache",
        ]
    )

    return cmds
