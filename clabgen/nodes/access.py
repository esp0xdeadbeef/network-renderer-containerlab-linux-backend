# ./clabgen/nodes/access.py
from __future__ import annotations


def render(node_name: str) -> str:
    return f"""    # ============================================================
    # ACCESS
    # ============================================================
    {node_name}:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip addr replace 10.10.0.0/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::/127 dev eth1
        - ip route replace 10.10.0.0/31 dev eth1 scope link
        - ip -6 route replace fd42:dead:beef:1000::/127 dev eth1
        - ip route replace default via 10.10.0.1 dev eth1
        - ip -6 route replace default via fd42:dead:beef:1000::1 dev eth1
"""
