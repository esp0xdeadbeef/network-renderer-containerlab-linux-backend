#!/usr/bin/env bash
# GAMP-ID: FS-520-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
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
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "allocation": "fixture-explicit",
                "tableId": 1001,
                "priority": 10001,
            },
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

eth_map = {"tenant": "tenant0", "wan": "wan0"}
main_defaults = _render_default_routes(node, eth_map)
policy_routes = render_policy_routes(node, eth_map)

if main_defaults:
    raise AssertionError(f"policy-only defaults leaked into main table: {main_defaults}")

joined = "\n".join(policy_routes)
assert "ip route replace table 1001 0.0.0.0/0 via 10.0.0.1 dev wan0 onlink" in joined
assert "ip -6 route replace table 1001 ::/0 via fd00::1 dev wan0 onlink" in joined
assert "ip rule add iif tenant0 priority 10001 table 1001" in joined
assert "ip -6 rule add iif tenant0 priority 10001 table 1001" in joined

upstream = {
    "interfaces": {
        "core": {
            "addr4": "10.50.0.15/31",
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
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "allocation": "fixture-explicit",
                "tableId": 1002,
                "priority": 10002,
            },
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

upstream_policy = "\n".join(
    render_policy_routes(upstream, {"core": "core0", "policy-client": "pol-client"})
)
assert (
    "ip route replace table 1002 10.50.20.0/24 via 10.50.0.32 dev pol-client onlink"
    in upstream_policy
)
assert (
    "ip route replace table 1002 10.50.20.0/24 via 10.50.0.14 dev core0 onlink"
    not in upstream_policy
)
assert "ip rule add to 10.50.20.0/24 iif core0 priority 10002 table 1002" in upstream_policy
assert "ip rule add iif core0 priority 10002 table 1002" not in upstream_policy
assert "ip rule add iif pol-client priority 10002 table 1002" in upstream_policy

policy_node = {
    "interfaces": {
        "downstream": {
            "addr4": "10.10.0.3/31",
            "addr6": "fd42:520:ff::3/127",
            "lane": {"kind": "access", "access": "client"},
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "allocation": "fixture-explicit",
                "tableId": 1001,
                "priority": 10001,
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "10.20.20.0/24",
                        "via4": "10.10.0.2",
                        "proto": "internal",
                    }
                ],
                "ipv6": [
                    {
                        "dst": "fd42:520:20::/64",
                        "via6": "fd42:520:ff::2",
                        "proto": "internal",
                    }
                ],
            },
        },
        "uplink": {
            "addr4": "10.10.0.6/31",
            "addr6": "fd42:520:ff::6/127",
            "lane": {
                "kind": "access-uplink",
                "access": "client",
                "uplink": "internet-vlan4",
                "uplinks": ["internet-vlan4"],
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "allocation": "fixture-explicit",
                "tableId": 1002,
                "priority": 10002,
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.10.0.7",
                        "policyOnly": True,
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client",
                            "uplink": "internet-vlan4",
                        },
                    }
                ],
                "ipv6": [
                    {
                        "dst": "::/0",
                        "via6": "fd42:520:ff::7",
                        "policyOnly": True,
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client",
                            "uplink": "internet-vlan4",
                        },
                    }
                ],
            },
        },
    }
}

policy_node_text = "\n".join(
    render_policy_routes(policy_node, {"downstream": "p0", "uplink": "p1"})
)
assert (
    "ip route replace table 1002 10.20.20.0/24 via 10.10.0.2 dev p0 onlink"
    in policy_node_text
)
assert (
    "ip -6 route replace table 1002 fd42:520:20::/64 via fd42:520:ff::2 dev p0 onlink"
    in policy_node_text
)
assert "ip route replace table 1002 10.20.20.0/24 via 10.10.0.7 dev p1 onlink" not in policy_node_text

print("PASS policy-no-main-defaults")
PY
