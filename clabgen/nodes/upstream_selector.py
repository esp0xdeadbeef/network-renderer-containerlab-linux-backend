from __future__ import annotations


def render(node_name: str, core_link_addr4: str) -> str:
    core_ip = core_link_addr4.split("/")[0]

    return f"""    # ============================================================
    # UPSTREAM SELECTOR
    # ============================================================
    {node_name}:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip link set eth2 up

        # core link
        - ip addr replace 10.10.0.3/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::3/127 dev eth1
        - ip route replace {core_link_addr4} dev eth1 scope link
        - ip -6 route replace fd42:dead:beef:1000::2/127 dev eth1

        # policy link
        - ip addr replace 10.10.0.5/31 dev eth2
        - ip -6 addr replace fd42:dead:beef:1000::5/127 dev eth2
        - ip route replace 10.10.0.4/31 dev eth2 scope link
        - ip -6 route replace fd42:dead:beef:1000::4/127 dev eth2

        # internal prefixes downstream
        - ip route replace 10.10.0.0/16 via 10.10.0.4 dev eth2
        - ip route replace 10.20.0.0/16 via 10.10.0.4 dev eth2
        - ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::4 dev eth2

        # default toward core
        - ip route replace default via {core_ip} dev eth1
        - ip -6 route replace default via fd42:dead:beef:1000::2 dev eth1
"""
