from __future__ import annotations

from typing import List


def render(role: str, node_name: str) -> List[str]:
    _ = node_name

    if role in {"core", "policy", "upstream-selector", "wan-peer", "isp"}:
        return [
            "sysctl -w net.ipv4.ip_forward=1",
            "sysctl -w net.ipv6.conf.all.forwarding=1",
        ]

    return []
