#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render as render_policy_routes
from clabgen.s88.CM.linux_routes import _render_default_routes

node = {
    "interfaces": {
        "tenant": {
            "lane": {"access": "client"},
        },
        "wan": {
            "addr4": "10.0.0.0/31",
            "addr6": "fd00::/127",
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.0.0.1",
                        "policyOnly": True,
                        "lane": {"access": "client"},
                    }
                ],
                "ipv6": [
                    {
                        "dst": "::/0",
                        "via6": "fd00::1",
                        "policyOnly": True,
                        "lane": {"access": "client"},
                    }
                ],
            },
        },
    }
}

eth_map = {"tenant": 1, "wan": 2}
main_defaults = _render_default_routes(node, eth_map)
policy_routes = render_policy_routes(node, eth_map)

if main_defaults:
    raise AssertionError(f"policy-only defaults leaked into main table: {main_defaults}")

joined = "\n".join(policy_routes)
assert "ip route replace table 1001 0.0.0.0/0 via 10.0.0.1 dev eth2 onlink" in joined
assert "ip -6 route replace table 1001 ::/0 via fd00::1 dev eth2 onlink" in joined
assert "ip rule add iif eth1 priority 10001 table 1001" in joined
assert "ip -6 rule add iif eth1 priority 10001 table 1001" in joined

upstream = {
    "interfaces": {
        "core": {
            "lane": {"uplink": "wan"},
            "routes": {
                "ipv4": [
                    {
                        "dst": "10.50.20.0/24",
                        "via4": "10.50.0.14",
                        "policyOnly": True,
                        "lane": {"access": "client", "uplink": "wan"},
                    }
                ],
            },
        },
        "policy-client": {
            "addr4": "10.50.0.33/31",
            "lane": {"access": "client", "uplink": "wan"},
            "routes": {
                "ipv4": [
                    {
                        "dst": "10.50.20.0/24",
                        "via4": "10.50.0.32",
                        "policyOnly": True,
                        "lane": {"access": "client", "uplink": "wan"},
                    },
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.50.0.14",
                        "policyOnly": True,
                        "lane": {"access": "client", "uplink": "wan"},
                    },
                ],
            },
        },
    }
}

upstream_policy = "\n".join(render_policy_routes(upstream, {"core": 1, "policy-client": 4}))
assert "ip route replace table 1004 10.50.20.0/24 via 10.50.0.32 dev eth4 onlink" in upstream_policy
assert "ip route replace table 1004 10.50.20.0/24 via 10.50.0.14 dev eth1 onlink" not in upstream_policy
assert "ip rule add iif eth1 priority 10004 table 1004" in upstream_policy
assert "ip rule add iif eth4 priority 10004 table 1004" in upstream_policy

print("PASS policy-no-main-defaults")
PY
