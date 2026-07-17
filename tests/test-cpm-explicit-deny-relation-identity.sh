#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010
# Verifies explicit CPM deny relations remain visible as Linux nftables drop
# rules with their relation identity in the CLAB renderer.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from copy import deepcopy

from clabgen.s88.EM.base import render as render_em


RELATION_ID = "deny-admin-dns-to-wan"


def policy_node(relation_id=RELATION_ID):
    rule = {
        "fromInterface": "tenant-admin",
        "toInterface": "wan-uplink",
        "action": "deny",
        "relationId": relation_id,
        "priority": 90,
        "trafficType": "dns",
        "from": {"kind": "tenant-set", "name": "admin"},
        "to": {"kind": "external", "name": "wan"},
        "matches": [
            {"family": "any", "proto": "udp", "dports": [53]},
            {"family": "any", "proto": "tcp", "dports": [53]},
        ],
    }
    if relation_id is None:
        del rule["relationId"]

    return {
        "routing_mode": "static",
        "interfaces": {
            "tenant-admin": {
                "kind": "tenant",
                "runtimeIfName": "ens10",
            },
            "wan-uplink": {
                "kind": "wan",
                "runtimeIfName": "ens11",
            },
        },
        "forwardingIntent": {
            "mode": "explicit-policy-forwarding",
            "rules": [rule],
        },
    }


def render_text(node_data):
    commands = render_em(
        "policy",
        "policy-node",
        deepcopy(node_data),
        {
            "tenant-admin": "ens10",
            "wan-uplink": "ens11",
        },
    )
    return "\n".join(commands)


def require_modeled_deny(text, relation_id):
    expected = [
        f'iifname "ens10" oifname "ens11" udp dport 53 counter drop comment "{relation_id}"',
        f'iifname "ens10" oifname "ens11" tcp dport 53 counter drop comment "{relation_id}"',
    ]
    missing = [needle for needle in expected if needle not in text]
    if missing:
        raise AssertionError(
            "explicit CPM deny relation was not rendered as typed drop rules "
            f"with relation identity; missing={missing!r}\n{text}"
        )

    forbidden = [
        f'accept comment "{relation_id}"',
        "counter drop comment",
    ]
    if forbidden[0] in text:
        raise AssertionError(f"deny relation rendered as accept:\n{text}")
    if text.count(f'comment "{relation_id}"') != 2:
        raise AssertionError(
            "expected exactly two typed DNS drop rules for the modeled deny "
            f"relation, got {text.count(f'comment \"{relation_id}\"')}:\n{text}"
        )


positive = render_text(policy_node())
require_modeled_deny(positive, RELATION_ID)

negative = render_text(policy_node(relation_id=None))
try:
    require_modeled_deny(negative, RELATION_ID)
except AssertionError:
    pass
else:
    raise AssertionError("seeded negative did not detect missing relation identity")

if 'add chain inet fw forward { type filter hook forward priority 0 ; policy drop ; }' not in positive:
    raise AssertionError(f"policy firewall chain did not default to drop:\n{positive}")

print("PASS cpm-explicit-deny-relation-identity")
PY
