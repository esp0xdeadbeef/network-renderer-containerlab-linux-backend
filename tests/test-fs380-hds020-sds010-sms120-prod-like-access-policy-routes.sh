#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-120
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render

node = {
    "role": "access",
    "interfaces": {
        "p2p-access-vlan2-downstream-selector": {
            "runtimeIfName": "p0",
            "addr4": "10.10.0.0/31",
            "backingRef": {
                "lane": {
                    "access": "access-vlan2",
                    "kind": "access-edge",
                },
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1002,
                "priority": 10002,
                "tableRulePriority": 1002,
                "mainSuppressPriority": 11002,
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.10.0.1",
                        "proto": "default",
                    },
                    {
                        "dst": "10.10.0.0/31",
                        "proto": "connected",
                    },
                ],
                "ipv6": [],
            },
        },
        "tenant-client": {
            "runtimeIfName": "lan2",
            "addr4": "10.38.120.1/24",
            "backingRef": {
                "lane": {
                    "access": "access-vlan2",
                    "kind": "tenant",
                },
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1001,
                "priority": 10001,
                "tableRulePriority": 1001,
                "mainSuppressPriority": 11001,
            },
            "routes": {
                "ipv4": [
                    {
                        "dst": "10.38.120.0/24",
                        "proto": "connected",
                    },
                ],
                "ipv6": [],
            },
        },
    },
    "forwardingIntent": {
        "rules": [
            {
                "action": "accept",
                "fromInterface": "lan2",
                "toInterface": "p0",
            },
            {
                "action": "accept",
                "fromInterface": "p0",
                "toInterface": "lan2",
            },
        ],
    },
}

text = "\n".join(
    render(
        node,
        {
            "p2p-access-vlan2-downstream-selector": "p0",
            "tenant-client": "lan2",
        },
    )
)

expected = [
    "ip route replace table 1001 10.38.120.0/24 dev lan2",
    "ip route replace table 1002 0.0.0.0/0 via 10.10.0.1 dev p0 onlink",
    "sh -c 'ip rule add from 10.38.120.0/24 iif lan2 priority 1002 table 1002 2>/dev/null || true'",
    "sh -c 'ip rule add to 10.38.120.0/24 iif p0 priority 1001 table 1001 2>/dev/null || true'",
    "sh -c 'ip rule add from 10.38.120.0/24 iif lan2 priority 11002 table main suppress_prefixlength 0 2>/dev/null || true'",
]

missing = [line for line in expected if line not in text]
if missing:
    raise AssertionError(
        "missing prod-like access policy-routing commands:\n"
        + "\n".join(missing)
        + "\n\nrendered:\n"
        + text
    )

for forbidden in [
    "ip route replace table 1001 blackhole 0.0.0.0/0",
    "ip route replace table 1002 blackhole 0.0.0.0/0",
    "ip rule add iif lan2 priority 1001 table 1001",
    "ip rule add iif lan2 priority 1002 table 1002",
    "ip rule add to 10.38.120.0/24 iif lan2 priority 1002 table 1002",
]:
    if forbidden in text:
        raise AssertionError(f"broad or blackhole client ingress rule rendered: {forbidden}\n{text}")

print("PASS FS-380-HDS-020-SDS-010-SMS-120 prod-like access policy routes")
PY
