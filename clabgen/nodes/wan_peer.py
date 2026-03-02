# ./clabgen/nodes/wan_peer.py
from __future__ import annotations


def render(node_name: str) -> str:
    return f"""    # ============================================================
    # WAN PEER (nftables-based SNAT)
    # ============================================================
    {node_name}:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up

        # CORE <-> WAN P2P
        - ip addr replace 10.19.0.65/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1900::65/127 dev eth1
        - ip route replace 10.19.0.64/31 dev eth1 scope link
        - ip -6 route replace fd42:dead:beef:1900::64/127 dev eth1

        # fabric return routes
        - ip route replace 10.10.0.0/16 via 10.19.0.64 dev eth1
        - ip route replace 10.20.0.0/16 via 10.19.0.64 dev eth1
        - ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1900::64 dev eth1

        # default to docker bridge
        - ip route replace default via 172.20.20.1 dev eth0

        # enable forwarding
        - sysctl -w net.ipv4.ip_forward=1
        - sysctl -w net.ipv6.conf.all.forwarding=1

        # nftables NAT (works without legacy iptables kernel modules)
        - nft flush ruleset
        - nft add table ip nat
        - nft 'add chain ip nat postrouting {{ type nat hook postrouting priority 100 ; }}'
        - nft add rule ip nat postrouting oifname "eth0" masquerade

        - ip route flush cache
        - ip -6 route flush cache
"""
