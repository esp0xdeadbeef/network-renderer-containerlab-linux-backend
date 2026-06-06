#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render

node = {
    "interfaces": {
        "policy-ingress": {
            "addr4": "10.50.44.41/31",
            "lane": {
                "access": "access-client",
                "kind": "access",
                "uplink": None,
                "uplinks": [],
            },
        },
        "ordinary-uplink": {
            "addr4": "10.50.44.62/31",
            "lane": {
                "access": "access-client",
                "kind": "access-uplink",
                "uplink": "wan",
                "uplinks": ["wan"],
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.50.44.63",
                        "policyOnly": True,
                        "proto": "default",
                    }
                ]
            },
        },
    }
}

cmds = render(node, {"policy-ingress": "ens20", "ordinary-uplink": "ordinary0"})
joined = "\n".join(cmds)

assert (
    "ip route replace table 1001 0.0.0.0/0 via 10.50.44.63 dev ordinary0 onlink"
    in joined
), joined
assert (
    "sh -c 'ip rule add iif ens20 priority 10001 table 1001 2>/dev/null || true'"
    in joined
), joined

print("PASS policy-ingress-interface-lane-default")
PY
