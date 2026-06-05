#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.policy_firewall import render


def explicit_deny(relation_id):
    return {
        "fromInterface": "down-client",
        "toInterface": "up-wan",
        "action": "deny",
        "trafficType": "dns",
        "family": 4,
        "relationId": relation_id,
        "comment": relation_id,
        "matches": [
            {"family": 4, "proto": "udp", "dports": [53]},
        ],
    }


commands = render(
    {
        "interface_tags": {},
        "rules": [
            explicit_deny("deny-explicit-cpm-a"),
            explicit_deny("deny-explicit-cpm-b"),
            explicit_deny("deny-explicit-cpm-b"),
        ],
    }
)

drop_commands = [
    command
    for command in commands
    if (
        'iifname "down-client"' in command
        and 'oifname "up-wan"' in command
        and "udp dport 53" in command
        and "counter drop" in command
    )
]

expected_a = (
    'nft add rule inet fw forward iifname "down-client" '
    'oifname "up-wan" udp dport 53 counter drop comment deny-explicit-cpm-a'
)
expected_b = (
    'nft add rule inet fw forward iifname "down-client" '
    'oifname "up-wan" udp dport 53 counter drop comment deny-explicit-cpm-b'
)

if expected_a not in drop_commands:
    raise AssertionError(f"missing first explicit deny command in: {drop_commands!r}")
if expected_b not in drop_commands:
    raise AssertionError(f"missing second explicit deny command in: {drop_commands!r}")
if len(drop_commands) != 2:
    raise AssertionError(f"expected two materialized unique deny commands, got {drop_commands!r}")

no_input_commands = render({"interface_tags": {}, "rules": []})
unexpected = [
    command
    for command in no_input_commands
    if (
        'iifname "down-client"' in command
        and 'oifname "up-wan"' in command
        and "counter drop" in command
    )
]
if unexpected:
    raise AssertionError(f"renderer inferred deny commands without CPM input: {unexpected!r}")

print("PASS cpm-explicit-deny-relation-identity")
PY
