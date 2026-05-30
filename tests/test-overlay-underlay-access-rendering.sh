#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import json
import tempfile
from pathlib import Path

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import render_units


def iface(link, runtime_if_name, addr4, addr6, routes=None):
    return {
        "sourceKind": "p2p",
        "runtimeIfName": runtime_if_name,
        "backingRef": {"name": link},
        "addr4": addr4,
        "addr6": addr6,
        "routes": routes or {"ipv4": [], "ipv6": []},
    }


underlay = "p2p-access-client-core-nebula"
upstream = "p2p-core-nebula-upstream"

def rt(name, role, loopback_id, interfaces):
    return {
        "logicalNode": {"name": name},
        "role": role,
        "routingMode": "static",
        "effectiveRuntimeRealization": {
            "loopback": {
                "addr4": f"10.59.0.{loopback_id}/32",
                "addr6": f"fd42:dead:feed:1900::{loopback_id}/128",
            },
            "interfaces": interfaces,
        },
    }


def adjacency(link, endpoints, lane):
    return {
        "kind": "p2p",
        "link": link,
        "endpoints": [{"unit": endpoint} for endpoint in endpoints],
        "lane": lane,
    }


root = {"control_plane_model": {"version": 1, "data": {"esp": {"clab": {}}}}}
site = root["control_plane_model"]["data"]["esp"]["clab"]
site["runtimeTargets"] = {
    "rt-access": rt(
        "clab-router-access-client",
        "access",
        1,
        {
            underlay: iface(
                underlay,
                "eth1",
                "10.50.0.2/31",
                "fd42:dead:feed:1000::2/127",
            )
        },
    ),
    "rt-core-nebula": rt(
        "clab-router-core-nebula",
        "core",
        2,
        {
            underlay: iface(
                underlay,
                "eth1",
                "10.50.0.3/31",
                "fd42:dead:feed:1000::3/127",
                {
                    "ipv4": [{"dst": "0.0.0.0/0", "via4": "10.50.0.2"}],
                    "ipv6": [{"dst": "::/0", "via6": "fd42:dead:feed:1000::2"}],
                },
            ),
            upstream: iface(
                upstream,
                "eth2",
                "10.50.0.14/31",
                "fd42:dead:feed:1000::e/127",
            ),
        },
    ),
    "rt-upstream": rt(
        "clab-router-upstream",
        "upstream-selector",
        3,
        {
            upstream: iface(
                upstream,
                "eth1",
                "10.50.0.15/31",
                "fd42:dead:feed:1000::f/127",
            )
        },
    ),
}
site["transit"] = {
    "adjacencies": [
        adjacency(
            underlay,
            ["clab-router-access-client", "clab-router-core-nebula"],
            {"class": "overlay-underlay", "trafficType": "nebula"},
        ),
        adjacency(
            upstream,
            ["clab-router-core-nebula", "clab-router-upstream"],
            {"class": "transit"},
        ),
    ]
}
site["tenantPrefixOwners"] = {}

with tempfile.TemporaryDirectory() as tmp:
    cpm_path = Path(tmp) / "cpm.json"
    cpm_path.write_text(json.dumps(root))
    sites = load_sites(cpm_path)
    nodes, links, bridges = render_units(sites["esp-clab"])

access_exec = "\n".join(nodes["clab-router-access-client"]["exec"])
core_exec = "\n".join(nodes["clab-router-core-nebula"]["exec"])

assert "10.50.0.2/31" in access_exec
assert "10.50.0.3/31" in core_exec
assert "ip route replace default" not in access_exec
assert "ip -6 route replace default" not in access_exec
assert (
    "ip route replace default via 10.50.0.2 dev eth1 onlink" in core_exec
), core_exec
assert (
    "ip -6 route replace default via fd42:dead:feed:1000::2 dev eth1 onlink"
    in core_exec
), core_exec
assert "via 10.50.0.15 dev eth2" not in core_exec
assert "via fd42:dead:feed:1000::f dev eth2" not in core_exec

matching_links = [
    link
    for link in links
    if sorted(link.get("endpoints", []))
    == [
        "clab-router-access-client:eth1",
        "clab-router-core-nebula:eth1",
    ]
]
assert len(matching_links) == 1, links
assert matching_links[0]["labels"]["clab.link.type"] == "bridge"
assert "clab.link.bridge" in matching_links[0]["labels"]
assert bridges

print("PASS overlay-underlay-access-rendering")
PY
