from __future__ import annotations


def render(node_name: str) -> str:
    return f"""    # ============================================================
    # POLICY
    # ============================================================
    {node_name}:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip link set eth2 up

        # access link
        - ip addr replace 10.10.0.1/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::1/127 dev eth1
        - ip route replace 10.10.0.0/31 dev eth1 scope link
        - ip -6 route replace fd42:dead:beef:1000::/127 dev eth1

        # upstream-selector link
        - ip addr replace 10.10.0.4/31 dev eth2
        - ip -6 addr replace fd42:dead:beef:1000::4/127 dev eth2
        - ip route replace 10.10.0.4/31 dev eth2 scope link
        - ip -6 route replace fd42:dead:beef:1000::4/127 dev eth2

        # upstream default
        - ip route replace default via 10.10.0.5 dev eth2
        - ip -6 route replace default via fd42:dead:beef:1000::5 dev eth2
"""
