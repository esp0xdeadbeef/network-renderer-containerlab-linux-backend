from __future__ import annotations

from typing import Any, Dict


def render(node_name: str, link_addr4: str) -> str:
    ip_only = link_addr4.split("/")[0]

    return f"""    # ============================================================
    # CORE
    # ============================================================
    {node_name}:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip link set eth2 up

        # upstream-selector link
        - ip addr replace {link_addr4} dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::2/127 dev eth1
        - ip route replace {link_addr4} dev eth1 scope link
        - ip -6 route replace fd42:dead:beef:1000::2/127 dev eth1

        # WAN P2P
        - ip addr replace 10.19.0.64/31 dev eth2
        - ip -6 addr replace fd42:dead:beef:1900::64/127 dev eth2
        - ip route replace 10.19.0.64/31 dev eth2 scope link
        - ip -6 route replace fd42:dead:beef:1900::64/127 dev eth2

        # internal aggregation
        - ip route replace 10.10.0.0/16 via 10.10.0.3 dev eth1
        - ip route replace 10.20.0.0/16 via 10.10.0.3 dev eth1
        - ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::3 dev eth1

        # default to WAN peer
        - ip route replace default via 10.19.0.65 dev eth2
        - ip -6 route replace default via fd42:dead:beef:1900::65 dev eth2
"""
