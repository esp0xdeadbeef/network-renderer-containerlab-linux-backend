# ./clabgen/s88/CM/forwarding.py
from __future__ import annotations

from typing import List, Dict, Any


def render(input_data: Dict[str, Any]) -> List[str]:
    enable_ipv4 = bool(input_data.get("enable_ipv4", False))
    enable_ipv6 = bool(input_data.get("enable_ipv6", False))
    disable_eth0 = bool(input_data.get("disable_eth0", False))

    cmds: List[str] = []

    if enable_ipv4:
        cmds.append("sysctl -w net.ipv4.ip_forward=1")

    if enable_ipv6:
        cmds.append("sysctl -w net.ipv6.conf.all.forwarding=1")

    if disable_eth0:
        if enable_ipv4:
            cmds.append(
                "test ! -d /proc/sys/net/ipv4/conf/eth0 || sysctl -w net.ipv4.conf.eth0.forwarding=0"
            )
        if enable_ipv6:
            cmds.append(
                "test ! -d /proc/sys/net/ipv6/conf/eth0 || sysctl -w net.ipv6.conf.eth0.forwarding=0"
            )

    return cmds
