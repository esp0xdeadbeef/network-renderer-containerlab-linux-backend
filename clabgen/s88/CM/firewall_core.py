# ./clabgen/s88/CM/firewall_core.py
from __future__ import annotations

from typing import List


def render(role: str, node_name: str) -> List[str]:
    _ = role
    _ = node_name

    return [
        "nft flush ruleset",
        "nft add table inet filter",
        "nft 'add chain inet filter input { type filter hook input priority 0 ; policy drop ; }'",
        "nft 'add chain inet filter forward { type filter hook forward priority 0 ; policy accept ; }'",
        "nft 'add chain inet filter output { type filter hook output priority 0 ; policy accept ; }'",
        "nft add rule inet filter input iif lo accept",
        "nft add rule inet filter input ct state established,related accept",
        "nft add rule inet filter input ct state invalid drop",
        "nft add rule inet filter input meta l4proto ipv6-icmp accept",
        'nft add rule inet filter input iifname "eth2" ip saddr { 0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4 } drop',
        'nft add rule inet filter input iifname "eth2" ip6 saddr { ::1,fc00::/7,fe80::/10 } drop',
        'nft add rule inet filter input iifname != "eth2" tcp dport 22 accept',
        "nft add rule inet filter forward ct state established,related accept",
        "nft add rule inet filter forward ct state invalid drop",
        'nft add rule inet filter forward iifname "eth2" ip saddr { 10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16 } drop',
        'nft add rule inet filter forward iifname "eth2" ip6 saddr fc00::/7 drop',
        "nft add table ip nat",
        "nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat ; policy accept ; }'",
        'nft add rule ip nat postrouting oifname "eth2" ip saddr { 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 } masquerade',
        "nft add table inet mangle",
        "nft 'add chain inet mangle forward { type filter hook forward priority mangle ; policy accept ; }'",
        'nft add rule inet mangle forward oifname "eth2" tcp flags syn tcp option maxseg size set rt mtu',
    ]
