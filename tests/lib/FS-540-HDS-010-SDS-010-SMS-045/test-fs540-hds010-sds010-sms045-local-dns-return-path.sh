#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-045
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render

node = {
    "role": "access",
    "interfaces": {
        "p2p-access-local-downstream-selector": {
            "runtimeIfName": "transit0",
            "addr4": "10.54.255.0/31",
            "addr6": "fd42:540:fe::/127",
            "backingRef": {
                "lane": {"access": "access-local", "kind": "access-edge"},
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
                        "via4": "10.54.255.1",
                        "proto": "default",
                        "intent": {"kind": "default-reachability"},
                    },
                    {"dst": "10.54.255.0/31", "proto": "connected"},
                ],
                "ipv6": [
                    {
                        "dst": "::/0",
                        "via6": "fd42:540:fe::1",
                        "proto": "default",
                        "intent": {"kind": "default-reachability"},
                    },
                    {"dst": "fd42:0540:00fe::/127", "proto": "connected"},
                ],
            },
        },
        "tenant-local-client": {
            "runtimeIfName": "lan0",
            "addr4": "10.54.46.1/24",
            "addr6": "fd42:0540:0046:0000:0000:0000:0000:0001/64",
            "backingRef": {
                "lane": {"access": "access-local", "kind": "tenant"},
            },
            "policyRoutingAllocation": {
                "source": "control-plane-model",
                "tableId": 1001,
                "priority": 10001,
                "tableRulePriority": 1001,
                "mainSuppressPriority": 11001,
            },
            "routes": {
                "ipv4": [{"dst": "10.54.46.0/24", "proto": "connected"}],
                "ipv6": [{"dst": "fd42:0540:0046::/64", "proto": "connected"}],
            },
        },
    },
    "forwardingIntent": {
        "rules": [
            {
                "action": "accept",
                "fromInterface": "lan0",
                "toInterface": "transit0",
            },
            {
                "action": "accept",
                "fromInterface": "transit0",
                "toInterface": "lan0",
            },
        ],
    },
    "services": {
        "dns": {
            "listen": ["10.54.46.1", "fd42:540:46::1"],
            "outgoingInterfaces": ["10.54.46.1", "fd42:540:46::1"],
        },
    },
}

eth_map = {
    "p2p-access-local-downstream-selector": "transit0",
    "tenant-local-client": "lan0",
}
rendered = "\n".join(render(node, eth_map))

required = [
    "sh -c 'ip route replace table 1002 10.54.46.0/24 dev lan0 2>/dev/null || true'",
    "sh -c 'ip -6 route replace table 1002 fd42:540:46::/64 dev lan0 2>/dev/null || true'",
    "sh -c 'ip rule add from 10.54.46.1/32 priority 1002 table 1002 2>/dev/null || true'",
    "sh -c 'ip -6 rule add from fd42:540:46::1/128 priority 1002 table 1002 2>/dev/null || true'",
]
missing = [line for line in required if line not in rendered]
if missing:
    raise AssertionError(
        "missing dual-stack local DNS return commands:\n"
        + "\n".join(missing)
        + "\n\nrendered:\n"
        + rendered
    )

for line in required[2:]:
    if " iif " in line:
        raise AssertionError(f"local DNS return rule must not require ingress context: {line}")

print("PASS FS-540-HDS-010-SDS-010-SMS-045 CLAB dual-stack local DNS return path")
PY
