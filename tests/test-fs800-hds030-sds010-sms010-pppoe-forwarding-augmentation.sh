#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-010-SMS-010
# Construction test: CLAB PPPoE Forwarding Rule Augmentation
# Proves: CLAB renderer augments forwardingIntent.rules with
# PPPoE-derived forwarding rules when services.pppoe is present
# and forwardingIntent already has at least one rule.
#
# SMS predicates verified:
#   - PPPoE client runtimeInterface causes accept rules to be added
#     between the PPP interface and existing forwarding peers.
#   - PPPoE-session interface records (sourceKind="pppoe-session")
#     are detected even without an explicit client runtimeInterface.
#   - Duplicate rules are not emitted when the path is already
#     covered by existing forwardingIntent.rules.
#   - Nodes without PPPoE services are not affected.
#   - Nodes with PPPoE but no existing forwardingIntent rules
#     are not affected (no inet fw to block traffic).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")

from clabgen.s88.EM.base import (
    _firewall_cm_input,
    _pppoe_session_interface_names,
    _augment_pppoe_forwarding_rules,
    _interface_name_map,
)

failures = 0

def fail(msg):
    global failures
    print(f"  FAIL: {msg}")
    failures += 1

def check(description, condition):
    global failures
    if condition:
        print(f"  PASS: {description}")
    else:
        fail(description)

# ============================================================
# FIXTURE 1: PPPoE client node with forwardingIntent rules
# (e.g. customer-side PPPoE container)
# ============================================================
print("=== Check 1: PPPoE client node gets augmented forwarding rules ===")

pppoe_client_node = {
    "name": "pppoe-customer",
    "role": "core",
    "interfaces": {
        "wan-egress": {
            "kind": "wan",
            "runtimeIfName": "ens20",
        },
        "us-transport": {
            "kind": "p2p",
            "runtimeIfName": "ens21",
        },
    },
    "services": {
        "pppoe": {
            "client": {
                "interface": "pppoe-handoff",
                "runtimeInterface": "ppp0",
                "defaultRoute": True,
                "usePeerDns": False,
                "mtu": 1492,
                "credentials": {"username": "test", "password": "test"},
            }
        }
    },
    "forwardingIntent": {
        "mode": "explicit-core-forwarding",
        "rules": [
            {
                "action": "accept",
                "fromInterface": "us-transport",
                "toInterface": "wan-egress",
                "relationId": "core-egress-rule",
            },
        ],
    },
}

eth_map = {
    "wan-egress": "ens20",
    "us-transport": "ens21",
    # ppp0 is NOT in eth_map — dynamically created by PPPoE daemon
}

result = _firewall_cm_input(pppoe_client_node, eth_map)
rules = result.get("rules", [])

# Should have 5 rules: 1 original + 4 augmented
# (2 peer interfaces x 2 directions = 4 PPPoE rules)
check("Result has 5 rules (1 original + 4 augmented)", len(rules) == 5)

# Check the original rule is preserved
original_present = any(
    r.get("fromInterface") == "ens21" and r.get("toInterface") == "ens20"
    for r in rules
)
check("Original forwarding rule preserved", original_present)

# Check the PPPoE-augmented rules for the peer interface (ens21)
rule_ens21_to_ppp0 = any(
    r.get("fromInterface") == "ens21"
    and r.get("toInterface") == "ppp0"
    and r.get("action") == "accept"
    and "pppoe-fabric" in str(r.get("relationId", ""))
    for r in rules
)
check("Augmented rule: ens21 -> ppp0 (access fabric -> PPP)", rule_ens21_to_ppp0)

rule_ppp0_to_ens21 = any(
    r.get("fromInterface") == "ppp0"
    and r.get("toInterface") == "ens21"
    and r.get("action") == "accept"
    and "pppoe-fabric" in str(r.get("relationId", ""))
    for r in rules
)
check("Augmented rule: ppp0 -> ens21 (PPP -> access fabric)", rule_ppp0_to_ens21)

# Also check the WAN interface (ens20) should have rules too
rule_ens20_to_ppp0 = any(
    r.get("fromInterface") == "ens20"
    and r.get("toInterface") == "ppp0"
    for r in rules
)
check("Augmented rule: ens20 -> ppp0 (ISP -> PPP)", rule_ens20_to_ppp0)

rule_ppp0_to_ens20 = any(
    r.get("fromInterface") == "ppp0"
    and r.get("toInterface") == "ens20"
    for r in rules
)
check("Augmented rule: ppp0 -> ens20 (PPP -> ISP)", rule_ppp0_to_ens20)


# ============================================================
# Seeded Negative 1: Node WITHOUT PPPoE services is unaffected
# ============================================================
print("\n=== Seeded Negative 1: No PPPoE services => no augmentation ===")

no_pppoe_node = {
    "name": "normal-core",
    "role": "core",
    "interfaces": {
        "wan-egress": {"kind": "wan", "runtimeIfName": "ens20"},
        "us-transport": {"kind": "p2p", "runtimeIfName": "ens21"},
    },
    "forwardingIntent": {
        "mode": "explicit-core-forwarding",
        "rules": [
            {
                "action": "accept",
                "fromInterface": "us-transport",
                "toInterface": "wan-egress",
            },
        ],
    },
}

result_no_pppoe = _firewall_cm_input(no_pppoe_node, eth_map)
rules_no_pppoe = result_no_pppoe.get("rules", [])
check("No PPPoE node has exactly 1 rule (original only)", len(rules_no_pppoe) == 1)
has_pppoe_rule = any("pppoe-fabric" in str(r.get("relationId", "")) for r in rules_no_pppoe)
check("No PPPoE node has zero pppoe-fabric rules", not has_pppoe_rule)


# ============================================================
# Seeded Negative 2: PPPoE services but NO forwardingIntent.rules
# ============================================================
print("\n=== Seeded Negative 2: PPPoE but no forwarding rules => no augmentation ===")
# When forwardingIntent has no rules, _firewall_cm_input returns {},
# which means no inet fw chain is created.  We must NOT create one
# just because PPPoE is present.

pppoe_no_rules_node = {
    "name": "pppoe-no-rules",
    "role": "core",
    "interfaces": {
        "wan-egress": {"kind": "wan", "runtimeIfName": "ens20"},
    },
    "services": {
        "pppoe": {
            "client": {
                "interface": "pppoe-handoff",
                "runtimeInterface": "ppp0",
                "defaultRoute": True,
                "usePeerDns": False,
                "mtu": 1492,
                "credentials": {"username": "test", "password": "test"},
            }
        }
    },
    "forwardingIntent": {
        "mode": "explicit-core-forwarding",
        "rules": [],  # empty list
    },
}

result_no_rules = _firewall_cm_input(pppoe_no_rules_node, {"wan-egress": "ens20"})
check("PPPoE with empty rules returns empty (no inet fw)", result_no_rules == {})


# ============================================================
# Seeded Negative 3: Duplicate rules are not emitted
# ============================================================
print("\n=== Seeded Negative 3: Duplicate rules are not emitted ===")

pppoe_with_existing_ppp_rule = {
    "name": "pppoe-with-existing",
    "role": "core",
    "interfaces": {
        "us-transport": {"kind": "p2p", "runtimeIfName": "ens21"},
    },
    "services": {
        "pppoe": {
            "client": {
                "interface": "pppoe-handoff",
                "runtimeInterface": "ppp0",
                "defaultRoute": True,
                "usePeerDns": False,
                "mtu": 1492,
                "credentials": {"username": "test", "password": "test"},
            }
        }
    },
    "forwardingIntent": {
        "mode": "explicit-core-forwarding",
        "rules": [
            {
                "action": "accept",
                "fromInterface": "us-transport",
                "toInterface": "ppp0",
                "relationId": "already-exists",
            },
        ],
    },
}

result_existing = _firewall_cm_input(
    pppoe_with_existing_ppp_rule, {"us-transport": "ens21"}
)
rules_existing = result_existing.get("rules", [])

# Should have the existing rule + the reverse rule (ppp0 -> ens21) only
check("Existing PPP rule + reverse rule = 2 total", len(rules_existing) == 2)
count_ens21_to_ppp0 = sum(
    1 for r in rules_existing
    if r.get("fromInterface") == "ens21" and r.get("toInterface") == "ppp0"
)
check("ens21 -> ppp0 appears exactly once (no duplicate)", count_ens21_to_ppp0 == 1)


# ============================================================
# Check 2: PPPoE-session interface records (sourceKind) detection
# ============================================================
print("\n=== Check 2: PPPoE-session interface kind detection ===")

# Simulate the CPM attaching a synthetic PPPoE-session interface
# (as done in build-target.nix for the server-side PPPoE provider)
pppoe_server_node = {
    "name": "pppoe-server",
    "role": "core",
    "interfaces": {
        "to-isp": {
            "kind": "wan",
            "runtimeIfName": "ens20",
        },
        "to-access-fabric": {
            "kind": "p2p",
            "runtimeIfName": "ens21",
        },
        "ppp0": {
            "kind": "pppoe-session",
            "runtimeIfName": "ppp0",
        },
    },
    "services": {
        "pppoe": {
            "server": {
                "interface": "pppoe-handoff",
                "providerAddress": "203.0.113.5",
                "customerAddress": "203.0.113.4",
                "maxSessions": 8,
                "mtu": 1492,
                "credentials": {"username": "test", "password": "test"},
            }
        }
    },
    "forwardingIntent": {
        "mode": "explicit-core-forwarding",
        "rules": [
            {
                "action": "accept",
                "fromInterface": "to-access-fabric",
                "toInterface": "to-isp",
                "relationId": "core-mesh-rule",
            },
        ],
    },
}

eth_map_server = {
    "to-isp": "ens20",
    "to-access-fabric": "ens21",
    # ppp0 is NOT in eth_map — it's a synthetic PPPoE-session interface
}

result_server = _firewall_cm_input(pppoe_server_node, eth_map_server)
rules_server = result_server.get("rules", [])

# Should have original rule + PPPoE-augmented rules
# The ppp0 interface should be detected via kind="pppoe-session"
check("Server node gets augmented rules (kind=pppoe-session detected)",
      len(rules_server) >= 3)

rule_ens21_to_ppp0_server = any(
    r.get("fromInterface") == "ens21"
    and r.get("toInterface") == "ppp0"
    for r in rules_server
)
check("Server: ens21 -> ppp0 rule generated", rule_ens21_to_ppp0_server)

rule_ppp0_to_ens21_server = any(
    r.get("fromInterface") == "ppp0"
    and r.get("toInterface") == "ens21"
    for r in rules_server
)
check("Server: ppp0 -> ens21 rule generated", rule_ppp0_to_ens21_server)


# ============================================================
# Check 3: Rendered nftables commands include PPPoE paths
# ============================================================
print("\n=== Check 3: Rendered nftables commands include PPPoE forwarding rules ===")

from clabgen.s88.CM.policy_firewall import render as render_policy_firewall

result_check3 = _firewall_cm_input(pppoe_client_node, eth_map)
fw_input = {
    "rules": result_check3.get("rules", []),
    "interface_tags": result_check3.get("interface_tags", {}),
}
cmds = render_policy_firewall(fw_input)
text = "\n".join(cmds)

check("nftables output contains iifname ens21 oifname ppp0 accept",
      'iifname "ens21" oifname "ppp0"' in text and 'counter accept' in text)
check("nftables output contains iifname ppp0 oifname ens21 accept",
      'iifname "ppp0" oifname "ens21"' in text and 'counter accept' in text)
check("nftables output contains iifname ens20 oifname ppp0 accept",
      'iifname "ens20" oifname "ppp0"' in text and 'counter accept' in text)
check("nftables output contains iifname ppp0 oifname ens20 accept",
      'iifname "ppp0" oifname "ens20"' in text and 'counter accept' in text)
check("nftables forward chain has policy drop",
      "policy drop" in text)
check("nftables forward chain has ct established,related accept",
      "ct state established,related accept" in text)
check("nftables forward chain has ct invalid drop",
      "ct state invalid drop" in text)

# Verify pppoe-fabric comment is in the output
check("nftables output contains pppoe-fabric comment",
      "pppoe-fabric" in text)


# ============================================================
# SUMMARY
# ============================================================
print()
if failures:
    print(f"FAIL FS-800-HDS-010-SDS-020-SMS-010: {failures} failure(s)")
    sys.exit(1)
else:
    print("PASS FS-800-HDS-010-SDS-020-SMS-010")
PY
