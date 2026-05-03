# ./clabgen/s88/CM/nat.py
from __future__ import annotations

from typing import List, Dict, Any


def render(input_data: Dict[str, Any]) -> List[str]:
    inside_interfaces = input_data.get("inside_interfaces", [])
    if not isinstance(inside_interfaces, list):
        inside_interfaces = []

    routes_v4 = input_data.get("routes_v4", [])
    routes_v6 = input_data.get("routes_v6", [])

    cmds: List[str] = [
        "sysctl -w net.ipv4.ip_forward=1",
        "sysctl -w net.ipv6.conf.all.forwarding=1",
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
        "nft flush ruleset",
        "nft add table ip nat",
        "nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'",
        'nft add rule ip nat postrouting oifname "eth0" masquerade',
    ]

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
