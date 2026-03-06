from __future__ import annotations

from typing import List


def render(role: str, node_name: str) -> List[str]:
    _ = node_name

    if role != "wan-peer":
        return []

    return [
        "nft flush ruleset",
        "nft add table ip nat",
        "nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'",
        'nft add rule ip nat postrouting oifname "eth0" masquerade',
        "ip route flush cache",
        "ip -6 route flush cache",
    ]
