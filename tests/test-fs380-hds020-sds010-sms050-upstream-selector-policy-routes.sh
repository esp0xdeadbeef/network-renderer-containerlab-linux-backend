#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render

node = {
    "role": "upstream-selector",
    "interfaces": {
        "core": {
            "runtimeIfName": "p0",
            "addr4": "10.10.0.5/31",
            "addr6": "fd42:380:ff::5/127",
            "backingRef": {
                "lane": "default",
                "uplinks": ["internet-vlan4", "internet-vlan5"],
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1001,
                "priority": 10001,
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.10.0.4",
                        "policyOnly": True,
                        "reason": "policy-derived-default",
                    },
                    {
                        "dst": "10.20.20.0/24",
                        "via4": "10.10.0.6",
                        "policyOnly": True,
                        "reason": "policy-table-internal-reachability",
                        "intent": {
                            "policyTableComplement": True,
                            "source": "policy-default-lane",
                        },
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client-edge",
                            "uplink": "internet-vlan4",
                            "uplinks": ["internet-vlan4"],
                        },
                    },
                    {
                        "dst": "10.20.20.0/24",
                        "via4": "10.10.0.8",
                        "policyOnly": True,
                        "reason": "policy-table-internal-reachability",
                        "intent": {
                            "policyTableComplement": True,
                            "source": "policy-default-lane",
                        },
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client-edge",
                            "uplink": "internet-vlan5",
                            "uplinks": ["internet-vlan5"],
                        },
                    },
                ],
                "ipv6": [
                    {
                        "dst": "::/0",
                        "via6": "fd42:380:ff::4",
                        "policyOnly": True,
                        "reason": "policy-derived-default",
                    },
                    {
                        "dst": "fd42:0380:0020:0000:0000:0000:0000:0000/64",
                        "via6": "fd42:380:ff::6",
                        "policyOnly": True,
                        "reason": "policy-table-internal-reachability",
                        "intent": {
                            "policyTableComplement": True,
                            "source": "policy-default-lane",
                        },
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client-edge",
                            "uplink": "internet-vlan4",
                            "uplinks": ["internet-vlan4"],
                        },
                    },
                    {
                        "dst": "fd42:0380:0020:0000:0000:0000:0000:0000/64",
                        "via6": "fd42:380:ff::8",
                        "policyOnly": True,
                        "reason": "policy-table-internal-reachability",
                        "intent": {
                            "policyTableComplement": True,
                            "source": "policy-default-lane",
                        },
                        "lane": {
                            "kind": "access-uplink",
                            "access": "client-edge",
                            "uplink": "internet-vlan5",
                            "uplinks": ["internet-vlan5"],
                        },
                    },
                ],
            },
        },
        "policy-vlan4": {
            "runtimeIfName": "p1",
            "addr4": "10.10.0.7/31",
            "addr6": "fd42:380:ff::7/127",
            "backingRef": {
                "lane": {
                    "kind": "access-uplink",
                    "access": "client-edge",
                    "uplink": "internet-vlan4",
                    "uplinks": ["internet-vlan4"],
                }
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1002,
                "priority": 10002,
            },
            "routes": {"ipv4": [], "ipv6": []},
        },
        "policy-vlan5": {
            "runtimeIfName": "p2",
            "addr4": "10.10.0.9/31",
            "addr6": "fd42:380:ff::9/127",
            "backingRef": {
                "lane": {
                    "kind": "access-uplink",
                    "access": "client-edge",
                    "uplink": "internet-vlan5",
                    "uplinks": ["internet-vlan5"],
                }
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1003,
                "priority": 10003,
            },
            "routes": {"ipv4": [], "ipv6": []},
        },
    },
}

text = "\n".join(render(node, {"core": "p0", "policy-vlan4": "p1", "policy-vlan5": "p2"}))

expected = [
    "ip route replace table 1001 0.0.0.0/0 via 10.10.0.4 dev p0 onlink",
    "ip route replace table 1001 10.20.20.0/24 nexthop via 10.10.0.6 dev p1 onlink nexthop via 10.10.0.8 dev p2 onlink",
    "ip -6 route replace table 1001 ::/0 via fd42:380:ff::4 dev p0 onlink",
    "ip -6 route replace table 1001 fd42:380:20::/64 nexthop via fd42:380:ff::6 dev p1 onlink nexthop via fd42:380:ff::8 dev p2 onlink",
    "sh -c 'ip rule add iif p0 priority 10001 table 1001 2>/dev/null || true'",
    "sh -c 'ip -6 rule add iif p0 priority 10001 table 1001 2>/dev/null || true'",
    "ip route replace table 1002 0.0.0.0/0 via 10.10.0.4 dev p0 onlink",
    "ip route replace table 1002 10.20.20.0/24 via 10.10.0.6 dev p1 onlink",
    "sh -c 'ip rule add iif p1 priority 10002 table 1002 2>/dev/null || true'",
    "ip route replace table 1003 0.0.0.0/0 via 10.10.0.4 dev p0 onlink",
    "ip route replace table 1003 10.20.20.0/24 via 10.10.0.8 dev p2 onlink",
    "sh -c 'ip rule add iif p2 priority 10003 table 1003 2>/dev/null || true'",
]

missing = [line for line in expected if line not in text]
if missing:
    raise AssertionError(
        "missing FS-380 upstream-selector policy routes:\n"
        + "\n".join(missing)
        + "\n\nrendered:\n"
        + text
    )

print("PASS FS-380 upstream-selector policy routes")
PY
