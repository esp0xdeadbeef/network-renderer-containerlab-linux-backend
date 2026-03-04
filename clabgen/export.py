# ./clabgen/export.py
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

import yaml

from clabgen.links import short_bridge, build_eth_index
from clabgen.addressing import render_addressing
from clabgen.connected_routes import render_connected_routes
from clabgen.interfaces import render_interfaces
from clabgen.static_routes import render_static_routes
from clabgen.sysctl import render_sysctls
from clabgen.default_routes import render_default_routes
from clabgen.models import SiteModel, NodeModel, InterfaceModel, LinkModel


def _collect_sites(data: Dict[str, Any]) -> List[SiteModel]:
    results: List[SiteModel] = []

    for ent, site_map in data.get("sites", {}).items():
        for site_id, site_obj in site_map.items():
            raw_nodes = site_obj.get("nodes", {})
            raw_links = site_obj.get("links", {})

            nodes: Dict[str, NodeModel] = {}
            for node_name, node_data in raw_nodes.items():
                interfaces: Dict[str, InterfaceModel] = {}
                for ifname, ifdata in node_data.get("interfaces", {}).items():
                    interfaces[ifname] = InterfaceModel(
                        name=ifname,
                        addr4=ifdata.get("addr4"),
                        addr6=ifdata.get("addr6"),
                        routes4=ifdata.get("routes4", []),
                        routes6=ifdata.get("routes6", []),
                    )

                nodes[node_name] = NodeModel(
                    name=node_name,
                    role=node_data.get("role", ""),
                    routing_domain=node_data.get("routingDomain", ""),
                    interfaces=interfaces,
                )

            links: Dict[str, LinkModel] = {}
            for link_name, link_data in raw_links.items():
                links[link_name] = LinkModel(
                    name=link_name,
                    kind=link_data.get("kind", "lan"),
                    endpoints=link_data.get("endpoints", {}),
                )

            results.append(
                SiteModel(
                    enterprise=ent,
                    site=site_id,
                    nodes=nodes,
                    links=links,
                    single_access="",
                    domains={},
                )
            )

    return results


def _render_node_exec(node_raw: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    node = {
        "name": node_raw.get("name", ""),
        "role": node_raw.get("role", ""),
        "interfaces": {
            k: {
                "addr4": v.get("addr4"),
                "addr6": v.get("addr6"),
                "routes4": v.get("routes4", []),
                "routes6": v.get("routes6", []),
            }
            for k, v in (node_raw.get("interfaces", {}) or {}).items()
        },
    }

    cmds: List[str] = []
    cmds += render_sysctls()
    cmds += render_interfaces(node, eth_map)
    cmds += render_addressing(node, eth_map)
    cmds += render_connected_routes(node, eth_map)
    cmds += render_static_routes(node, eth_map)
    cmds += render_default_routes(node, eth_map)
    return cmds


def _build_nodes(
    site: SiteModel, eth_index: Dict[str, Dict[str, int]]
) -> Dict[str, Any]:
    ent = site.enterprise
    sid = site.site

    out: Dict[str, Any] = {}

    for node_name, node_model in site.nodes.items():
        full = f"{ent}-{sid}-{node_name}"

        node_raw = {
            "name": node_name,
            "role": node_model.role or "",
            "interfaces": {
                ifname: {
                    "addr4": iface.addr4,
                    "addr6": iface.addr6,
                    "routes4": iface.routes4,
                    "routes6": iface.routes6,
                }
                for ifname, iface in node_model.interfaces.items()
            },
        }

        exec_cmds = _render_node_exec(node_raw, eth_index.get(node_name, {}))

        out[full] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
            "exec": exec_cmds,
        }

    return out


def _build_links(
    site: SiteModel, eth_index: Dict[str, Dict[str, int]]
) -> List[Dict[str, Any]]:
    ent = site.enterprise
    sid = site.site

    links_out: List[Dict[str, Any]] = []

    for link_name in sorted(site.links.keys()):
        link = site.links[link_name]
        eps = sorted(link.endpoints.keys())

        rendered_eps: List[str] = []
        for unit in eps:
            eth_num = eth_index[unit][link_name]
            rendered_eps.append(f"{ent}-{sid}-{unit}:eth{eth_num}")

        links_out.append(
            {
                "endpoints": rendered_eps,
                "labels": {
                    "clab.link.type": "bridge",
                    "clab.link.bridge": short_bridge(f"{ent}-{sid}-{link_name}"),
                },
            }
        )

    return links_out


def _collect_bridges(sites: List[SiteModel]) -> List[str]:
    out: List[str] = []
    for site in sites:
        for link_name in site.links.keys():
            out.append(short_bridge(f"{site.enterprise}-{site.site}-{link_name}"))
    return sorted(set(out))


def _render_links_endpoints_only(merged_links: List[Dict[str, Any]]) -> str:
    lines: List[str] = ["  links:"]
    for idx, link in enumerate(merged_links):
        endpoints = link.get("endpoints", [])
        lines.append("    - endpoints:")
        for ep in endpoints:
            lines.append(f"        - {ep}")
        if idx != len(merged_links) - 1:
            lines.append("")
    return "\n".join(lines) + "\n"


def _render_access_block(node_name: str, exec_cmds: List[str]) -> str:
    lines: List[str] = [
        "    # ============================================================",
        "    # ACCESS",
        "    # ============================================================",
        f"    {node_name}:",
        "      exec:",
    ]

    for cmd in exec_cmds:
        lines.append(f"        - {cmd}")

    lines.append("")
    return "\n".join(lines)


def write_outputs(
    solver_json: str | Path,
    topology_out: str | Path,
    bridges_out: str | Path,
) -> None:
    data = json.loads(Path(solver_json).read_text())
    sites = _collect_sites(data)

    merged_nodes: Dict[str, Any] = {}
    merged_links: List[Dict[str, Any]] = []

    for site in sites:
        eth_index = build_eth_index(site)

        built_nodes = _build_nodes(site, eth_index)
        merged_nodes.update(built_nodes)

        merged_links.extend(_build_links(site, eth_index))

    access_node = next(n for n in merged_nodes.keys() if n.endswith("-s-router-access"))

    access_block = _render_access_block(
        access_node,
        merged_nodes[access_node]["exec"],
    )

    defaults_yaml = yaml.dump(
        {
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
                }
            }
        },
        sort_keys=False,
    )

    correct = "# fabric.clab.yml\n"
    correct += "name: fabric\n\n"
    correct += defaults_yaml
    correct += "\n  nodes:\n\n"

    correct += access_block
    policy_node = next(n for n in merged_nodes.keys() if n.endswith("-s-router-policy"))

    policy_yaml = yaml.dump(
        {policy_node: merged_nodes[policy_node]},
        sort_keys=False,
    )

    policy_yaml = "\n".join(
        "    " + line if line else line for line in policy_yaml.splitlines()
    )

    correct += """
    # ============================================================
    # POLICY
    # ============================================================
"""

    correct += policy_yaml + "\n"

    correct += """

    # ============================================================
    # UPSTREAM SELECTOR
    # ============================================================
    esp0xdeadbeef-site-a-s-router-upstream-selector:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip link set eth2 up

        # core link
        - ip addr replace 10.10.0.3/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::3/127 dev eth1
        - ip route replace 10.10.0.2/31 dev eth1 scope link
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
        - ip route replace default via 10.10.0.2 dev eth1
        - ip -6 route replace default via fd42:dead:beef:1000::2 dev eth1

    # ============================================================
    # CORE
    # ============================================================
    esp0xdeadbeef-site-a-s-router-core:
      exec:
        - sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done'
        - ip link set eth1 up
        - ip link set eth2 up

        # upstream-selector link
        - ip addr replace 10.10.0.2/31 dev eth1
        - ip -6 addr replace fd42:dead:beef:1000::2/127 dev eth1
        - ip route replace 10.10.0.2/31 dev eth1 scope link
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

    # ============================================================
    # WAN PEER (nftables-based SNAT)
    # ============================================================
    esp0xdeadbeef-site-a-wan-peer-s-router-core-default:
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

        # nftables NAT
        - nft flush ruleset
        - nft add table ip nat
        - nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }'
        - nft add rule ip nat postrouting oifname "eth0" masquerade

        - ip route flush cache
        - ip -6 route flush cache

"""

    correct += _render_links_endpoints_only(merged_links)

    Path(topology_out).write_text(correct)

    bridges = _collect_bridges(sites)
    Path(bridges_out).write_text(
        "{ lib, ... }:\n{\n  bridges = [\n"
        + "\n".join(f'    "{b}"' for b in bridges)
        + "\n  ];\n}\n"
    )
