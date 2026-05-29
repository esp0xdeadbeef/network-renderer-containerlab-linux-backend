#!/usr/bin/env bash
# GAMP-ID: SMT-CLAB-ROLE-INDEPENDENT-CM-001
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.base import render


def assert_has(cmds, needle):
    text = "\n".join(cmds)
    if needle not in text:
        raise AssertionError(f"missing {needle!r} in:\n{text}")


explicit_wan_firewall = render(
    {
        "wan_firewall": {
            "wan_interfaces": ["eth9"],
            "masquerade": {"ipv4": True, "oifnames": ["eth9"]},
        }
    }
)
assert_has(explicit_wan_firewall, 'iifname "eth9"')
assert_has(explicit_wan_firewall, "nft add table ip nat")
assert_has(explicit_wan_firewall, 'oifname "eth9" masquerade')

explicit_policy_firewall = render(
    {
        "firewall": {
            "interface_tags": {
                "eth1": "inside",
                "eth2": "outside",
            },
            "rules": [
                {
                    "src_tenant": "inside",
                    "dst_tenant": "outside",
                    "action": "accept",
                    "matches": [{"proto": "tcp", "dports": [443]}],
                }
            ],
        }
    }
)
assert_has(explicit_policy_firewall, 'iifname "eth1" oifname "eth2" tcp dport 443 counter accept')

cpm_shape_firewall = render(
    {
        "firewall": {
            "rules": [
                {
                    "fromInterface": "uplink-a",
                    "toInterface": "uplink-b",
                    "action": "accept",
                    "trafficType": "dns",
                    "family": 4,
                    "sourcePrefixes": [{"family": 4, "prefix": "10.20.30.0/24"}],
                }
            ],
            "interface_tags": {},
        }
    }
)
assert_has(cpm_shape_firewall, 'iifname "uplink-a" oifname "uplink-b" ip saddr 10.20.30.0/24 udp dport 53 counter accept')
assert_has(cpm_shape_firewall, 'iifname "uplink-a" oifname "uplink-b" ip saddr 10.20.30.0/24 tcp dport 53 counter accept')

try:
    render({"made_up_policy": {"enabled": True}})
except ValueError as exc:
    message = str(exc)
    if "made_up_policy" not in message or "supported inputs" not in message:
        raise AssertionError(f"unsupported input error was not diagnostic: {message}")
else:
    raise AssertionError("unsupported explicit CM input did not fail visibly")

print("PASS role-independent-cm-inputs")
PY
