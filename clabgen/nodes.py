from __future__ import annotations

from typing import Dict, Any, List


def _get(obj: Any, key: str, default=None):
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def render_node(node: Any, eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    name = _get(node, "name", "") or ""

    def eth(idx: int) -> str:
        return f"eth{idx}"

    # ============================================================
    # ACCESS
    # ============================================================
    if name.endswith("-s-router-access"):
        cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            f"ip link set {eth(1)} up",
            f"ip addr replace 10.10.0.0/31 dev {eth(1)}",
            f"ip -6 addr replace fd42:dead:beef:1000::/127 dev {eth(1)}",
            f"ip route replace 10.10.0.0/31 dev {eth(1)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::/127 dev {eth(1)}",
            f"ip route replace default via 10.10.0.1 dev {eth(1)}",
            f"ip -6 route replace default via fd42:dead:beef:1000::1 dev {eth(1)}",
        ]

    # ============================================================
    # POLICY
    # ============================================================
    elif name.endswith("-s-router-policy"):
        cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            f"ip link set {eth(1)} up",
            f"ip link set {eth(2)} up",
            f"ip addr replace 10.10.0.1/31 dev {eth(1)}",
            f"ip -6 addr replace fd42:dead:beef:1000::1/127 dev {eth(1)}",
            f"ip route replace 10.10.0.0/31 dev {eth(1)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::/127 dev {eth(1)}",
            f"ip addr replace 10.10.0.4/31 dev {eth(2)}",
            f"ip -6 addr replace fd42:dead:beef:1000::4/127 dev {eth(2)}",
            f"ip route replace 10.10.0.4/31 dev {eth(2)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::4/127 dev {eth(2)}",
            f"ip route replace default via 10.10.0.5 dev {eth(2)}",
            f"ip -6 route replace default via fd42:dead:beef:1000::5 dev {eth(2)}",
        ]

    # ============================================================
    # UPSTREAM SELECTOR
    # ============================================================
    elif name.endswith("-s-router-upstream-selector"):
        cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            f"ip link set {eth(1)} up",
            f"ip link set {eth(2)} up",
            f"ip addr replace 10.10.0.3/31 dev {eth(1)}",
            f"ip -6 addr replace fd42:dead:beef:1000::3/127 dev {eth(1)}",
            f"ip route replace 10.10.0.2/31 dev {eth(1)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::2/127 dev {eth(1)}",
            f"ip addr replace 10.10.0.5/31 dev {eth(2)}",
            f"ip -6 addr replace fd42:dead:beef:1000::5/127 dev {eth(2)}",
            f"ip route replace 10.10.0.4/31 dev {eth(2)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::4/127 dev {eth(2)}",
            f"ip route replace 10.10.0.0/16 via 10.10.0.4 dev {eth(2)}",
            f"ip route replace 10.20.0.0/16 via 10.10.0.4 dev {eth(2)}",
            f"ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::4 dev {eth(2)}",
            f"ip route replace default via 10.10.0.2 dev {eth(1)}",
            f"ip -6 route replace default via fd42:dead:beef:1000::2 dev {eth(1)}",
        ]

    # ============================================================
    # CORE
    # ============================================================
    elif name.endswith("-s-router-core"):
        cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            f"ip link set {eth(1)} up",
            f"ip link set {eth(2)} up",
            f"ip addr replace 10.10.0.2/31 dev {eth(1)}",
            f"ip -6 addr replace fd42:dead:beef:1000::2/127 dev {eth(1)}",
            f"ip route replace 10.10.0.2/31 dev {eth(1)} scope link",
            f"ip -6 route replace fd42:dead:beef:1000::2/127 dev {eth(1)}",
            f"ip addr replace 10.19.0.64/31 dev {eth(2)}",
            f"ip -6 addr replace fd42:dead:beef:1900::64/127 dev {eth(2)}",
            f"ip route replace 10.19.0.64/31 dev {eth(2)} scope link",
            f"ip -6 route replace fd42:dead:beef:1900::64/127 dev {eth(2)}",
            f"ip route replace 10.10.0.0/16 via 10.10.0.3 dev {eth(1)}",
            f"ip route replace 10.20.0.0/16 via 10.10.0.3 dev {eth(1)}",
            f"ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::3 dev {eth(1)}",
            f"ip route replace default via 10.19.0.65 dev {eth(2)}",
            f"ip -6 route replace default via fd42:dead:beef:1900::65 dev {eth(2)}",
        ]

    # ============================================================
    # WAN PEER
    # ============================================================
    elif name.endswith("-wan-peer-s-router-core-default"):
        cmds = [
            "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
            f"ip link set {eth(1)} up",
            f"ip addr replace 10.19.0.65/31 dev {eth(1)}",
            f"ip -6 addr replace fd42:dead:beef:1900::65/127 dev {eth(1)}",
            f"ip route replace 10.19.0.64/31 dev {eth(1)} scope link",
            f"ip -6 route replace fd42:dead:beef:1900::64/127 dev {eth(1)}",
            f"ip route replace 10.10.0.0/16 via 10.19.0.64 dev {eth(1)}",
            f"ip route replace 10.20.0.0/16 via 10.19.0.64 dev {eth(1)}",
            f"ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1900::64 dev {eth(1)}",
            "ip route replace default via 172.20.20.1 dev eth0",
            "sysctl -w net.ipv4.ip_forward=1",
            "sysctl -w net.ipv6.conf.all.forwarding=1",
            "nft flush ruleset",
            "nft add table ip nat",
            "nft add chain ip nat postrouting { type nat hook postrouting priority 100 \\; }",
            'nft add rule ip nat postrouting oifname "eth0" masquerade',
            "ip route flush cache",
            "ip -6 route flush cache",
        ]

    return cmds
