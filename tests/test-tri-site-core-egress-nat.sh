#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

TMP_DIR="${tmp_dir}" python3 - <<'PY'
from pathlib import Path
import os
import json

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import render_units

tmp = Path(os.environ["TMP_DIR"])
cpm = {
    "control_plane_model": {
        "version": 1,
        "data": {
            "esp": {
                "clab": {
                    "runtimeTargets": {
                        "esp-clab-router-core-simulated-isp": {
                            "role": "core",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp",
                                "site": "clab",
                                "name": "clab-router-core-simulated-isp",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "upstream": {
                                        "sourceKind": "p2p",
                                        "addr4": "10.50.0.14/31",
                                        "addr6": "fd42:dead:feed:1000::e/127",
                                        "backingRef": {"name": "upstream"},
                                    },
                                    "wan": {
                                        "sourceKind": "wan",
                                        "upstream": "wan",
                                        "hostUplink": {
                                            "bridge": "br-uplink1",
                                            "mode": "vlan",
                                            "parent": "eth0",
                                            "vlan": 4,
                                        },
                                        "backingRef": {"name": "wan"},
                                    },
                                }
                            },
                        }
                    },
                    "transit": {
                        "adjacencies": [
                            {
                                "link": "upstream",
                                "kind": "p2p",
                                "endpoints": [
                                    {"unit": "clab-router-core-simulated-isp"},
                                    {"unit": "clab-router-upstream"},
                                ],
                            }
                        ]
                    },
                    "forwardingSemantics": {
                        "nodes": {
                            "clab-router-core-simulated-isp": {
                                "egressIntent": {
                                    "exit": True,
                                    "wanInterfaces": ["wan"],
                                    "uplinks": ["wan"],
                                },
                                "natIntent": {
                                    "enabled": True,
                                    "families": {"ipv4": True, "ipv6": True},
                                    "wanInterfaces": ["wan"],
                                    "masqueradeInterfaces": ["wan"],
                                    "masqueradeSourcePrefixes6": [
                                        "fd42:dead:feed:10::/64"
                                    ],
                                },
                            }
                        }
                    },
                }
            }
        },
    }
}
(tmp / "cpm.json").write_text(json.dumps(cpm))
inventory = {}
sites = load_sites(tmp / "cpm.json", renderer_inventory=inventory)
site = sites["esp-clab"]
nodes, _links, _bridges = render_units(site)
core = nodes["clab-router-core-simulated-isp"]
execs = core.get("exec") or []

want4 = 'nft add rule ip nat postrouting ip saddr { 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 } oifname "eth2" masquerade'
want6 = 'nft add rule ip6 nat postrouting ip6 saddr { fd42:dead:feed:10::/64 } oifname "eth2" masquerade'

assert want4 in execs, "missing NAT44 from explicit CPM natIntent on CLAB simulated ISP core"
assert want6 in execs, "missing NAT66 from explicit CPM natIntent on CLAB simulated ISP core"

print("PASS tri-site-core-egress-nat")
PY
