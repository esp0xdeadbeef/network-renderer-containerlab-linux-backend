#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-NOPOLICY
# GAMP-SCOPE: software-module-test (CMC focused test)
# Renderer No-Policy No-Emission Construction Test
#
# Proves the CLAB renderer emits zero invented nftables policy when CPM
# provides no forwarding rules, no NAT, no DNS kill-switch, no firewall
# contracts.  Only platform constants (management egress guard) are expected.
# Includes a seeded negative proving the test can detect nftables rules
# when CPM DOES provide forwarding policy.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import json
import re
import sys
import tempfile
from pathlib import Path

from clabgen.s88.enterprise.enterprise import Enterprise


# ═══════════════════════════════════════════════════════════════════════════════
# 1. Build minimal solver JSON: bare topology, zero policy contracts
# ═══════════════════════════════════════════════════════════════════════════════

def make_bare_solver_json():
    """Construct the smallest valid solver JSON possible.

    A single site, single core node, one p2p link.  No forwardingIntent,
    no natIntent, no services, no communicationContract, no
    sharedServicePolicyAtoms, no exposureClass.
    """
    return {
        "enterprise": {
            "esp0xdeadbeef": {
                "site": {
                    "site-a": {
                        "nodes": {
                            "bare-node": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "loopback": {
                                    "ipv4": "10.255.0.1/32",
                                },
                                "interfaces": {
                                    "bare-link": {
                                        "addr4": "192.0.2.0/31",
                                        "kind": "p2p",
                                        "runtimeIfName": "ens10",
                                    },
                                },
                            },
                        },
                        "links": {
                            "bare-link": {
                                "kind": "p2p",
                                "endpoints": {
                                    "bare-node": {
                                        "interface": "bare-link",
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# 2. Extract nftables commands from rendered topology
# ═══════════════════════════════════════════════════════════════════════════════

def extract_all_exec_cmds(rendered):
    """Extract all exec commands from all nodes in the rendered topology."""
    cmds = []
    topo = rendered.get("topology", {})
    for node_name, node_def in topo.get("nodes", {}).items():
        if not isinstance(node_def, dict):
            continue
        exec_cmds = node_def.get("exec", [])
        if not isinstance(exec_cmds, list):
            continue
        for cmd in exec_cmds:
            if isinstance(cmd, str):
                cmds.append(cmd)
    return cmds


def extract_nft_commands(cmds):
    """Filter exec commands to those containing nft/nftables references."""
    nft_cmds = []
    for cmd in cmds:
        if re.search(r'(?:^|\b)nft(?:\s|ables\s)', cmd):
            nft_cmds.append(cmd)
    return nft_cmds


# ═══════════════════════════════════════════════════════════════════════════════
# 3. Classify nftables rules
# ═══════════════════════════════════════════════════════════════════════════════

# PLATFORM_CONSTANTS: rules always emitted regardless of CPM policy.
# These are necessary for the CLAB platform to function correctly.
PLATFORM_SIGNATURES = {
    # management_egress_guard.py — always emitted for every node
    "inet clab_guard": {
        "source": "management_egress_guard.py",
        "rationale": "eth0 management egress guard — always needed regardless of CPM policy",
    },
}

# Policy-bearing signatures that should only appear when CPM provides
# corresponding contracts.
POLICY_SIGNATURES = {
    "inet filter": {
        "source": "firewall_wan.py",
        "trigger": "wan_interfaces (natIntent.wanInterfaces or forwardingIntent.uplinkInterfaces)",
    },
    "inet mangle": {
        "source": "firewall_wan.py",
        "trigger": "wan_interfaces (natIntent.wanInterfaces or forwardingIntent.uplinkInterfaces)",
    },
    "inet fw": {
        "source": "policy_firewall.py",
        "trigger": "forwardingIntent.rules",
    },
    "inet clab_dns_guard": {
        "source": "dns_service.py",
        "trigger": "services.dns.killSwitch.blockPublicResolvers + deniedResolverCidrs",
    },
    "ip nat": {
        "source": "firewall_wan.py / nat.py",
        "trigger": "natIntent.enabled + families.ipv4",
    },
    "ip6 nat": {
        "source": "firewall_wan.py / nat.py",
        "trigger": "natIntent.enabled + families.ipv6",
    },
}


def classify_nft_commands(nft_cmds):
    """Classify each nft command as PLATFORM_CONSTANT or POLICY_INVENTION.

    Returns (platform_count, invention_lines, all_lines) where
    invention_lines is a list of (cmd, classification) tuples.
    """
    platform_count = 0
    inventions = []

    for cmd in nft_cmds:
        matched = False
        # Check platform signatures first
        for sig, info in PLATFORM_SIGNATURES.items():
            if sig in cmd:
                platform_count += 1
                matched = True
                break
        if matched:
            continue

        # Check if it matches any known policy signature
        for sig, info in POLICY_SIGNATURES.items():
            if sig in cmd:
                inventions.append((cmd, info))
                matched = True
                break

        if not matched:
            # Unrecognized nft command — could be new platform constant
            # or new policy invention
            inventions.append((
                cmd,
                {
                    "source": "UNKNOWN",
                    "trigger": "unrecognized — may be new platform constant or new policy source",
                },
            ))

    return platform_count, inventions


def render_solver(solver_json):
    """Render solver JSON through the Enterprise pipeline. Returns rendered dict."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, dir="/tmp"
    ) as f:
        json.dump(solver_json, f)
        solver_path = f.name

    try:
        enterprise = Enterprise.from_solver_json(solver_path, renderer_inventory={})
        rendered = enterprise.render()
    finally:
        Path(solver_path).unlink()

    return rendered


# ═══════════════════════════════════════════════════════════════════════════════
# 4. Main test: bare topology → zero policy invention
# ═══════════════════════════════════════════════════════════════════════════════

bare_solver = make_bare_solver_json()
print("=== Bare topology render ===")
bare_rendered = render_solver(bare_solver)

all_cmds = extract_all_exec_cmds(bare_rendered)
nft_cmds = extract_nft_commands(all_cmds)
print(f"Total exec commands: {len(all_cmds)}")
print(f"Nftables commands: {len(nft_cmds)}")

for i, cmd in enumerate(nft_cmds):
    print(f"  [{i}] {cmd[:150]}{'...' if len(cmd) > 150 else ''}")

platform_count, inventions = classify_nft_commands(nft_cmds)
print(f"\nPlatform constants: {platform_count}")
print(f"Policy inventions:  {len(inventions)}")

if inventions:
    print("\n--- POLICY_INVENTION DETAILS ---")
    for cmd, info in inventions:
        print(f"  SOURCE:   {info.get('source', '?')}")
        print(f"  TRIGGER:  {info.get('trigger', '?')}")
        print(f"  COMMAND:  {cmd[:200]}{'...' if len(cmd) > 200 else ''}")
        print()

    total_inventions = len(inventions)
    # Classify further: which are from known policy modules vs unrecognized
    known_policy = sum(
        1 for _, info in inventions
        if info.get('source', 'UNKNOWN') != 'UNKNOWN'
    )
    unknown = total_inventions - known_policy

    if known_policy > 0:
        print(f"FAIL: {known_policy} nftables command(s) from known policy modules "
              f"emitted WITHOUT corresponding CPM policy input")
    if unknown > 0:
        print(f"FAIL: {unknown} unrecognized nftables command(s) emitted")

    print("\nThe renderer invented nftables policy that should come from CPM contracts.")
    print("Zero policy in → zero policy out expected.")
    sys.exit(1)

print("\nPASS: Zero invented policy. Renderer is policy-transparent with empty CPM input.")
print(f"  Only {platform_count} platform-constant nftables command(s) emitted "
      f"(management egress guard).")
print()


# ═══════════════════════════════════════════════════════════════════════════════
# 5. Seeded negative: inject forwarding rule → verify emission
# ═══════════════════════════════════════════════════════════════════════════════

print("=== Seeded negative: inject forwardingIntent rule ===")

# Make a copy of the bare solver and add a forwardingIntent rule
seeded_solver = json.loads(json.dumps(bare_solver))
site = seeded_solver["enterprise"]["esp0xdeadbeef"]["site"]["site-a"]
node = site["nodes"]["bare-node"]

# Add a second interface so the forwarding rule has valid from/to targets
node["interfaces"]["bare-link-2"] = {
    "addr4": "192.0.2.2/31",
    "kind": "p2p",
    "runtimeIfName": "ens11",
}

# Add a link for the second interface
site["links"]["bare-link-2"] = {
    "kind": "p2p",
    "endpoints": {
        "bare-node": {
            "interface": "bare-link-2",
        },
    },
}

# Now inject a forwardingIntent rule between the two interfaces
node["forwardingIntent"] = {
    "rules": [
        {
            "fromInterface": "bare-link",
            "toInterface": "bare-link-2",
            "action": "accept",
            "relationId": "test-bare-accept",
            "family": 4,
            "trafficType": "any",
        },
    ],
}

seeded_rendered = render_solver(seeded_solver)
seeded_all_cmds = extract_all_exec_cmds(seeded_rendered)
seeded_nft_cmds = extract_nft_commands(seeded_all_cmds)
print(f"Seeded nftables commands: {len(seeded_nft_cmds)}")

for i, cmd in enumerate(seeded_nft_cmds):
    print(f"  [{i}] {cmd[:150]}{'...' if len(cmd) > 150 else ''}")

seeded_platform, seeded_inventions = classify_nft_commands(seeded_nft_cmds)

# We expect INCREASED nftables commands compared to bare
# The additional commands should be from policy_firewall.py (inet fw table)
bare_nft_count = len(nft_cmds)
seeded_nft_count = len(seeded_nft_cmds)

if seeded_nft_count <= bare_nft_count:
    print(f"FAIL: Seeded negative did NOT increase nftables count "
          f"(bare={bare_nft_count}, seeded={seeded_nft_count})")
    print("  The test cannot detect policy when it exists — test is DORMANT")
    sys.exit(1)

print(f"  Bare nft count:  {bare_nft_count}")
print(f"  Seeded nft count: {seeded_nft_count} (+{seeded_nft_count - bare_nft_count})")

# Verify the specific inet fw table appears in seeded output
fw_table_found = any("inet fw" in cmd for cmd in seeded_nft_cmds)
if not fw_table_found:
    print("FAIL: Seeded negative did NOT produce 'inet fw' nftables table")
    print("  Expected policy_firewall.py to emit inet fw rules for the injected forwarding rule")
    print("  The test would miss policy emission if the CPM provided forwarding rules")
    sys.exit(1)

print("  inet fw table: PRESENT ✓")

# Verify the specific forwarding rule appears
fw_rule_found = any(
    "nft add rule inet fw forward" in cmd and "ens10" in cmd
    for cmd in seeded_nft_cmds
)
if not fw_rule_found:
    print("FAIL: Seeded negative did NOT produce forwarding rule for ens10")
    print("  Expected materialized nft rule for the injected forwardingIntent rule")
    sys.exit(1)

print("  Forwarding rule: PRESENT ✓")

# Verify the platform constants are still present
clab_guard_found = any("clab_guard" in cmd for cmd in seeded_nft_cmds)
if not clab_guard_found:
    print("FAIL: Platform constants missing in seeded output")
    print("  Expected management egress guard (clab_guard) even with policy present")
    sys.exit(1)

print("  Platform constants: PRESENT ✓")

print("\nSEEDED NEGATIVE PASS: test correctly detects nftables policy when CPM provides it")
print(f"  Additional {seeded_nft_count - bare_nft_count} commands emitted from injected forwardingIntent rule")
print()


# ═══════════════════════════════════════════════════════════════════════════════
# 6. Final summary
# ═══════════════════════════════════════════════════════════════════════════════

print("PASS test-no-policy-no-nftables-emission")
print("  Bare CPM input: 0 invented nftables policy (platform constants only)")
print("  Seeded negative: correctly detects policy emission when CPM provides it")
print("  Renderer is policy-transparent: zero policy in → zero policy out")
PY
