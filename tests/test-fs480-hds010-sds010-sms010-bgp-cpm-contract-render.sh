#!/usr/bin/env bash
# GAMP-ID: FS-480-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-520-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-780-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: renderer-hat-preparation
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.site.topology import render_site_topology

site = SiteModel(
    enterprise="hat",
    site="bgp-two-node",
    single_access="",
    domains={},
    nodes={
        "edge-a": NodeModel(
            name="edge-a",
            role="core",
            routing_domain="core",
            routing_mode="bgp",
            loopback4="10.255.0.1/32",
            bgp={
                "asn": 65010,
                "neighbors": [
                    {
                        "peer_addr4": "192.0.2.2/31",
                        "peer_addr6": "2001:db8:100::2/127",
                        "peer_asn": 65020,
                    }
                ],
            },
            interfaces={
                "to-edge-b": InterfaceModel(
                    name="to-edge-b",
                    runtime_if_name="eth1",
                    kind="wan",
                    addr4="192.0.2.1/31",
                    addr6="2001:db8:100::1/127",
                ),
                "tenant-a": InterfaceModel(
                    name="tenant-a",
                    runtime_if_name="eth2",
                    kind="tenant",
                    tenant="office",
                    addr4="10.10.10.1/24",
                    addr6="fd42:10:10::1/64",
                ),
            },
        ),
        "edge-b": NodeModel(
            name="edge-b",
            role="core",
            routing_domain="core",
            routing_mode="bgp",
            loopback4="10.255.0.2/32",
            bgp={
                "asn": 65020,
                "neighbors": [
                    {
                        "peer_addr4": "192.0.2.1/31",
                        "peer_addr6": "2001:db8:100::1/127",
                        "peer_asn": 65010,
                    }
                ],
            },
            interfaces={
                "to-edge-a": InterfaceModel(
                    name="to-edge-a",
                    runtime_if_name="eth1",
                    kind="wan",
                    addr4="192.0.2.2/31",
                    addr6="2001:db8:100::2/127",
                ),
                "tenant-b": InterfaceModel(
                    name="tenant-b",
                    runtime_if_name="eth2",
                    kind="tenant",
                    tenant="office",
                    addr4="10.20.20.1/24",
                    addr6="fd42:20:20::1/64",
                ),
            },
        ),
    },
    links={
        "bgp-handoff": LinkModel(
            name="bgp-handoff",
            kind="wan",
            bridge="br-bgp-handoff",
            endpoints={
                "edge-a": {"interface": "to-edge-b"},
                "edge-b": {"interface": "to-edge-a"},
            },
        )
    },
)

topology = render_site_topology(site)
nodes = topology["topology"]["nodes"]
edge_a = "\n".join(nodes["edge-a"]["exec"])
edge_b = "\n".join(nodes["edge-b"]["exec"])

assert "router bgp 65010" in edge_a
assert "neighbor 192.0.2.2 remote-as 65020" in edge_a
assert "neighbor 2001:db8:100::2 remote-as 65020" in edge_a
assert "network 10.10.10.0/24" in edge_a
assert "network fd42:10:10::/64" in edge_a

assert "router bgp 65020" in edge_b
assert "neighbor 192.0.2.1 remote-as 65010" in edge_b
assert "neighbor 2001:db8:100::1 remote-as 65010" in edge_b
assert "network 10.20.20.0/24" in edge_b
assert "network fd42:20:20::/64" in edge_b

assert "neighbor 10.255" not in edge_a + edge_b
assert "route-reflector-client" not in edge_a + edge_b
assert any(set(link["endpoints"]) == {"edge-a:eth1", "edge-b:eth1"} for link in topology["topology"]["links"])
PY

echo "PASS bgp-cpm-contract-render"
