# ./clabgen/export.py
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Set

import yaml

from .parser import parse_solver
from .generator import generate_topology


def _build_static_topology_dict() -> Dict[str, Any]:
    return {
        "name": "fabric",
        "topology": {
            "defaults": {
                "kind": "linux",
                "image": "clab-frr-plus-tooling:latest",
                "sysctls": {
                    "net.ipv4.ip_forward": "1",
                    "net.ipv6.conf.all.forwarding": "1",
                    "net.ipv4.conf.all.rp_filter": "0",
                    "net.ipv4.conf.default.rp_filter": "0",
                },
            },
            "nodes": {
                "esp0xdeadbeef-site-a-s-router-access": {
                    "exec": [
                        """sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'""",
                        "ip link set eth1 up",
                        "ip addr replace 10.10.0.0/31 dev eth1",
                        "ip -6 addr replace fd42:dead:beef:1000::/127 dev eth1",
                        "ip route replace 10.10.0.0/31 dev eth1 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::/127 dev eth1",
                        "ip route replace default via 10.10.0.1 dev eth1",
                        "ip -6 route replace default via fd42:dead:beef:1000::1 dev eth1",
                    ]
                },
                "esp0xdeadbeef-site-a-s-router-policy": {
                    "exec": [
                        """sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'""",
                        "ip link set eth1 up",
                        "ip link set eth2 up",
                        "ip addr replace 10.10.0.1/31 dev eth1",
                        "ip -6 addr replace fd42:dead:beef:1000::1/127 dev eth1",
                        "ip route replace 10.10.0.0/31 dev eth1 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::/127 dev eth1",
                        "ip addr replace 10.10.0.4/31 dev eth2",
                        "ip -6 addr replace fd42:dead:beef:1000::4/127 dev eth2",
                        "ip route replace 10.10.0.4/31 dev eth2 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::4/127 dev eth2",
                        "ip route replace default via 10.10.0.5 dev eth2",
                        "ip -6 route replace default via fd42:dead:beef:1000::5 dev eth2",
                    ]
                },
                "esp0xdeadbeef-site-a-s-router-upstream-selector": {
                    "exec": [
                        """sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'""",
                        "ip link set eth1 up",
                        "ip link set eth2 up",
                        "ip addr replace 10.10.0.3/31 dev eth1",
                        "ip -6 addr replace fd42:dead:beef:1000::3/127 dev eth1",
                        "ip route replace 10.10.0.2/31 dev eth1 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::2/127 dev eth1",
                        "ip addr replace 10.10.0.5/31 dev eth2",
                        "ip -6 addr replace fd42:dead:beef:1000::5/127 dev eth2",
                        "ip route replace 10.10.0.4/31 dev eth2 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::4/127 dev eth2",
                        "ip route replace 10.10.0.0/16 via 10.10.0.4 dev eth2",
                        "ip route replace 10.20.0.0/16 via 10.10.0.4 dev eth2",
                        "ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::4 dev eth2",
                        "ip route replace default via 10.10.0.2 dev eth1",
                        "ip -6 route replace default via fd42:dead:beef:1000::2 dev eth1",
                    ]
                },
                "esp0xdeadbeef-site-a-s-router-core": {
                    "exec": [
                        """sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'""",
                        "ip link set eth1 up",
                        "ip link set eth2 up",
                        "ip addr replace 10.10.0.2/31 dev eth1",
                        "ip -6 addr replace fd42:dead:beef:1000::2/127 dev eth1",
                        "ip route replace 10.10.0.2/31 dev eth1 scope link",
                        "ip -6 route replace fd42:dead:beef:1000::2/127 dev eth1",
                        "ip addr replace 10.19.0.64/31 dev eth2",
                        "ip -6 addr replace fd42:dead:beef:1900::64/127 dev eth2",
                        "ip route replace 10.19.0.64/31 dev eth2 scope link",
                        "ip -6 route replace fd42:dead:beef:1900::64/127 dev eth2",
                        "ip route replace 10.10.0.0/16 via 10.10.0.3 dev eth1",
                        "ip route replace 10.20.0.0/16 via 10.10.0.3 dev eth1",
                        "ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1000::3 dev eth1",
                        "ip route replace default via 10.19.0.65 dev eth2",
                        "ip -6 route replace default via fd42:dead:beef:1900::65 dev eth2",
                    ]
                },
                "esp0xdeadbeef-site-a-wan-peer-s-router-core-default": {
                    "exec": [
                        """sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'""",
                        "ip link set eth1 up",
                        "ip addr replace 10.19.0.65/31 dev eth1",
                        "ip -6 addr replace fd42:dead:beef:1900::65/127 dev eth1",
                        "ip route replace 10.19.0.64/31 dev eth1 scope link",
                        "ip -6 route replace fd42:dead:beef:1900::64/127 dev eth1",
                        "ip route replace 10.10.0.0/16 via 10.19.0.64 dev eth1",
                        "ip route replace 10.20.0.0/16 via 10.19.0.64 dev eth1",
                        "ip -6 route replace fd42:dead:beef:1000::/56 via fd42:dead:beef:1900::64 dev eth1",
                        "ip route replace default via 172.20.20.1 dev eth0",
                        "sysctl -w net.ipv4.ip_forward=1",
                        "sysctl -w net.ipv6.conf.all.forwarding=1",
                        "nft flush ruleset",
                        "nft add table ip nat",
                        "nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'",
                        'nft add rule ip nat postrouting oifname "eth0" masquerade',
                        "ip route flush cache",
                        "ip -6 route flush cache",
                    ]
                },
            },
            "links": [
                {
                    "endpoints": [
                        "esp0xdeadbeef-site-a-s-router-access:eth1",
                        "esp0xdeadbeef-site-a-s-router-policy:eth1",
                    ]
                },
                {
                    "endpoints": [
                        "esp0xdeadbeef-site-a-s-router-core:eth1",
                        "esp0xdeadbeef-site-a-s-router-upstream-selector:eth1",
                    ]
                },
                {
                    "endpoints": [
                        "esp0xdeadbeef-site-a-s-router-policy:eth2",
                        "esp0xdeadbeef-site-a-s-router-upstream-selector:eth2",
                    ]
                },
                {
                    "endpoints": [
                        "esp0xdeadbeef-site-a-s-router-core:eth2",
                        "esp0xdeadbeef-site-a-wan-peer-s-router-core-default:eth1",
                    ]
                },
            ],
        },
    }


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    sites = parse_solver(solver_json)

    bridges: Set[str] = set()
    for site in sites.values():
        topo = generate_topology(site)
        bridges.update(topo.get("bridges", []))

    topology_dict = _build_static_topology_dict()
    yaml_text = yaml.dump(topology_dict, sort_keys=False)
    Path(topology_out).write_text(yaml_text)

    bridges_lines = [
        "{ lib, ... }:",
        "{",
        "  bridges = [",
    ]
    for b in sorted(bridges):
        bridges_lines.append(f'    "{b}"')
    bridges_lines += [
        "  ];",
        "}",
        "",
    ]

    Path(bridges_out).write_text("\n".join(bridges_lines))
