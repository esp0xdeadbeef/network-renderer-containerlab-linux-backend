#!/usr/bin/env bash
# GAMP-ID: FS-760-HDS-010-SDS-010-SMS-010
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.CM.policy_firewall import render as render_policy_firewall
from clabgen.s88.site.policy_context import build_policy_firewall_state


def access_node(name, tenant):
    return NodeModel(
        name=name,
        role="access",
        routing_domain="test",
        interfaces={
            "tenant": InterfaceModel(
                name="tenant",
                kind="tenant",
                tenant=tenant,
                runtime_if_name=f"{tenant}0",
            )
        },
        routing_mode="static",
    )


policy_node = NodeModel(
    name="policy",
    role="policy",
    routing_domain="test",
    interfaces={
        "trusted-facing": InterfaceModel(
            name="trusted-facing",
            runtime_if_name="ens25",
        ),
        "iot-facing": InterfaceModel(
            name="iot-facing",
            runtime_if_name="ens23",
        ),
    },
    routing_mode="static",
    forwarding_intent={
        "mode": "explicit-policy-forwarding",
        "rules": [
            {
                "action": "accept",
                "applyTcpMssClamp": False,
                "comment": "shared-service-discovery-policy:fs760-receiver-discovery-policy",
                "from": {"kind": "tenant", "name": "trusted"},
                "fromInterface": "trusted-facing",
                "intent": {
                    "kind": "shared-service-discovery-policy",
                    "policyAtomId": "fs760-receiver-discovery-policy",
                    "service": "hat-receiver-discovery",
                    "serviceClass": "media-receiver",
                    "sms": "FS-760-HDS-010-SDS-010-SMS-010",
                },
                "matches": [
                    {"dports": [5353], "family": "any", "proto": "udp"},
                    {"dports": [1900], "family": "any", "proto": "udp"},
                ],
                "priority": 119,
                "relationId": "fs760-receiver-discovery-policy",
                "to": {"kind": "tenant", "name": "iot"},
                "toInterface": "iot-facing",
                "trafficType": "cast-discovery",
            }
        ],
    },
)

site = SiteModel(
    enterprise="test",
    site="clab",
    nodes={
        "access-iot": access_node("access-iot", "iot"),
        "access-trusted": access_node("access-trusted", "trusted"),
        "policy": policy_node,
    },
    links={
        "trusted-link": LinkModel(
            name="trusted-link",
            kind="p2p",
            endpoints={
                "access-trusted": {"interface": "tenant"},
                "policy": {"interface": "trusted-facing"},
            },
        ),
        "iot-link": LinkModel(
            name="iot-link",
            kind="p2p",
            endpoints={
                "access-iot": {"interface": "tenant"},
                "policy": {"interface": "iot-facing"},
            },
        ),
    },
    single_access="trusted",
    domains={},
    raw_policy={
        "trafficTypes": [
            {
                "name": "dns",
                "match": [
                    {"family": "any", "proto": "udp", "dports": [53]},
                    {"family": "any", "proto": "tcp", "dports": [53]},
                ],
            }
        ],
        "allowedRelations": [
            {
                "action": "deny",
                "from": {"kind": "tenant", "name": "trusted"},
                "id": "deny-trusted-dns-to-iot",
                "to": {"kind": "tenant", "name": "iot"},
                "trafficType": "dns",
            }
        ],
    },
)

state = build_policy_firewall_state(
    site,
    "policy",
    {"trusted-facing": "ens25", "iot-facing": "ens23"},
)
rules = state.get("rules") or []
fs760_rules = [
    rule
    for rule in rules
    if isinstance(rule, dict)
    and rule.get("relationId") == "fs760-receiver-discovery-policy"
]
if len(fs760_rules) != 1:
    raise AssertionError(f"expected one FS-760 forwarding rule in policy state: {rules!r}")

fs760 = fs760_rules[0]
if fs760.get("fromInterface") != "ens25" or fs760.get("toInterface") != "ens23":
    raise AssertionError(f"FS-760 rule was not normalized to runtime interfaces: {fs760!r}")
if (fs760.get("intent") or {}).get("policyAtomId") != "fs760-receiver-discovery-policy":
    raise AssertionError(f"FS-760 policy atom identity was not preserved: {fs760!r}")
if fs760.get("trafficType") != "cast-discovery":
    raise AssertionError(f"FS-760 traffic type was not preserved: {fs760!r}")

cmds = render_policy_firewall(state)
text = "\n".join(cmds)
expected = [
    'iifname "ens25" oifname "ens23" udp dport 5353 counter accept comment fs760-receiver-discovery-policy',
    'iifname "ens25" oifname "ens23" udp dport 1900 counter accept comment fs760-receiver-discovery-policy',
    'iifname "ens25" oifname "ens23" udp dport 53 counter drop',
    'iifname "ens25" oifname "ens23" tcp dport 53 counter drop',
]
for needle in expected:
    if needle not in text:
        raise AssertionError(f"missing {needle!r} in rendered policy firewall:\n{text}")

if "tcp dport 8008" in text or "tcp dport 8009" in text:
    raise AssertionError(f"FS-760 discovery renderer inferred receiver payload ports:\n{text}")

dns_drop_index = text.index('udp dport 53 counter drop')
fs760_index = text.index('udp dport 5353 counter accept comment fs760-receiver-discovery-policy')
if dns_drop_index > fs760_index:
    raise AssertionError(f"raw DNS deny ordering moved behind FS-760 CPM rule:\n{text}")

print("PASS fs760-policy-firewall-forwarding-intent")
PY
