#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-050
# Renderer nftables Primitive Source-Binding Construction Test
#
# Classifies every nftables table, chain, hook, priority, family, policy,
# and verdict primitive in rendered CLAB output against the platform-native
# nftables primitive registry. Includes a seeded negative case proving
# the checker rejects unregistered primitives.
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
from clabgen.nftables_primitive_registry import (
    REGISTRY,
    is_registered,
    get_binding,
    unregistered_report,
    list_registered,
    all_categories,
)


# ═══════════════════════════════════════════════════════════════════════════════
# 1. Build mock CPM solver JSON with features that emit nftables commands
# ═══════════════════════════════════════════════════════════════════════════════

def make_solver_json():
    """Construct a solver-format JSON that triggers multiple CM modules.

    Produces nodes that generate:
    - inet filter / inet mangle / ip nat tables (firewall_wan.py via core with WAN+NAT)
    - inet fw table (policy_firewall.py via core with forwardingIntent rules)
    - inet clab_dns_guard table (dns_service.py via core with DNS kill-switch)
    """
    return {
        "enterprise": {
            "esp0xdeadbeef": {
                "site": {
                    "site-a": {
                        "nodes": {
                            "core-router": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "loopback": {
                                    "ipv4": "10.255.0.1/32",
                                },
                                "interfaces": {
                                    "to-access": {
                                        "runtimeIfName": "ens10",
                                        "kind": "p2p",
                                        "addr4": "192.0.2.0/31",
                                    },
                                    "to-wan": {
                                        "runtimeIfName": "ens11",
                                        "kind": "wan",
                                        "addr4": "198.51.100.1/24",
                                    },
                                    "tenant-admin": {
                                        "runtimeIfName": "ens20",
                                        "kind": "tenant",
                                        "tenant": "admin",
                                        "addr4": "10.20.15.1/24",
                                    },
                                    "tenant-client": {
                                        "runtimeIfName": "ens21",
                                        "kind": "tenant",
                                        "tenant": "client",
                                        "addr4": "10.20.20.1/24",
                                    },
                                },
                                "natIntent": {
                                    "enabled": True,
                                    "families": {
                                        "ipv4": True,
                                        "ipv6": False,
                                    },
                                    "masqueradeInterfaces": ["to-wan"],
                                    "wanInterfaces": ["to-wan"],
                                },
                                "forwardingIntent": {
                                    "rules": [
                                        {
                                            "fromInterface": "tenant-admin",
                                            "toInterface": "to-wan",
                                            "action": "accept",
                                            "relationId": "allow-admin-egress",
                                            "sourceScope": {"tenant": "admin"},
                                            "destinationScope": {"internet": True},
                                            "family": 4,
                                            "trafficType": "any",
                                        },
                                        {
                                            "fromInterface": "to-wan",
                                            "toInterface": "tenant-client",
                                            "action": "drop",
                                            "relationId": "deny-external-to-client",
                                            "family": 4,
                                        },
                                    ],
                                },
                                "services": {
                                    "dns": {
                                        "listen": ["10.20.15.1"],
                                        "forwarders": ["8.8.8.8"],
                                        "outgoingInterfaces": ["to-wan"],
                                        "blockPublicResolvers": True,
                                        "deniedResolverCidrs": [
                                            "8.8.4.4/32",
                                            "2001:4860:4860::8888/128",
                                        ],
                                    },
                                },
                            },
                        },
                        "links": {
                            "p2p-access": {
                                "kind": "p2p",
                                "endpoints": {
                                    "core-router": {"interface": "to-access"},
                                },
                            },
                            "p2p-wan": {
                                "kind": "p2p",
                                "endpoints": {
                                    "core-router": {"interface": "to-wan"},
                                },
                            },
                        },
                    }
                }
            }
        }
    }


# ═══════════════════════════════════════════════════════════════════════════════
# 2. Extract nftables commands from rendered topology
# ═══════════════════════════════════════════════════════════════════════════════

def extract_nft_commands(rendered):
    """Extract all nft/nftables commands from rendered topology node exec fields."""
    commands = []
    topo = rendered.get("topology", {})
    for node_name, node_def in topo.get("nodes", {}).items():
        if not isinstance(node_def, dict):
            continue
        exec_cmds = node_def.get("exec", [])
        if not isinstance(exec_cmds, list):
            continue
        for cmd in exec_cmds:
            if not isinstance(cmd, str):
                continue
            # Match nft commands (may be wrapped in sh -c '...' or sh -c "...")
            # Look for 'nft ' or 'nftables ' anywhere in the command string
            if re.search(r'(?:^|\b)nft(?:\s|ables\s)', cmd):
                commands.append(cmd)
    return commands


# ═══════════════════════════════════════════════════════════════════════════════
# 3. Parse nftables primitives from command strings
# ═══════════════════════════════════════════════════════════════════════════════

def parse_nft_primitives(nft_commands):
    """Parse table names, chain names, hooks, priorities, families, policies,
    and verdicts from a list of nft command strings.

    Returns a dict of category -> set of values.
    """
    primitives = {cat: set() for cat in all_categories()}

    for cmd in nft_commands:
        # ── Tables: "nft add table <family> <name>" ──
        for m in re.finditer(r'nft\s+add\s+table\s+(\S+)\s+(\S+)', cmd):
            family, name = m.group(1), m.group(2)
            # Normalize: strip shell quotes and trailing punctuation
            name = name.strip("'\"")
            primitives["tables"].add(f"{family} {name}")

        # ── Chains: extract from add/flush/list chain AND add rule ──
        # Pattern: nft [optional quotes] add/flush/list chain family table CHAIN
        # Also: nft [optional quotes] add rule family table CHAIN ...
        for m in re.finditer(
            r'nft\s+(?:\'|")?\s*(?:add|flush|list)\s+(?:chain|rule)\s+'
            r'(\S+)\s+(\S+)\s+(\S+)',
            cmd,
        ):
            family, table, chain = m.group(1), m.group(2), m.group(3)
            # Strip shell quotes and trailing punctuation from chain name
            chain = chain.strip("'\"")
            primitives["chains"].add(chain)
            # Also register the table used with this chain/rule
            primitives["tables"].add(f"{family} {table}")

        # ── Add chain with full spec: "nft 'add chain ... { type <hook> hook <hook_type> priority <pri> ; ... }'" ──
        # Extract hook type, hook, priority, policy from chain definition
        chain_def_pattern = (
            r"type\s+(\S+)\s+hook\s+(\S+)\s+priority\s+(\S+)\s*;"
            r"\s*(?:policy\s+(\S+)\s*;)?"
        )
        for m in re.finditer(chain_def_pattern, cmd):
            hook_type = m.group(1)  # filter, nat, route
            hook = m.group(2)       # input, forward, output, postrouting, prerouting
            priority = m.group(3)   # 0, -50, mangle, 100, 101, etc.
            policy = m.group(4)     # accept, drop (optional)

            primitives["hooks"].add(hook_type)
            primitives["hook_types"].add(hook)
            primitives["priorities"].add(priority)
            if policy:
                primitives["policies"].add(policy)

        # ── Families from inline rule matches: "ip saddr", "ip6 saddr", "ip daddr", "ip6 daddr" ──
        for m in re.finditer(r'\b(ip|ip6)\s+(?:saddr|daddr)\b', cmd):
            primitives["families"].add(m.group(1))

        # ── Verdicts from rule actions: "... accept", "... drop", "... masquerade", "... snat" ──
        for m in re.finditer(r'(?:\bcounter\s+)?\b(accept|drop|masquerade|snat|dnat)\b', cmd):
            primitives["verdicts"].add(m.group(1))

    return primitives


# ═══════════════════════════════════════════════════════════════════════════════
# 4. Cross-reference primitives against registry
# ═══════════════════════════════════════════════════════════════════════════════

def check_primitives(primitives):
    """Check all parsed primitives against the registry.

    Returns (violations, report_lines) where violations is a list of
    (category, value) tuples and report_lines is a human-readable report.
    """
    violations = []
    report = []

    for category in all_categories():
        values = primitives.get(category, set())
        if not values:
            report.append(f"  {category}: (none found in rendered output)")
            continue

        registered = sorted(list_registered(category))
        found = sorted(values)
        report.append(f"  {category}: found {found}")

        for value in sorted(values):
            if not is_registered(category, value):
                violations.append((category, value))
                report.append(f"    -> {unregistered_report(category, value)}")
            else:
                binding = get_binding(category, value)
                report.append(f"    -> OK: {value!r} (source: {binding['source']})")

    return violations, report


# ═══════════════════════════════════════════════════════════════════════════════
# 5. Seeded negative case injector and checker
# ═══════════════════════════════════════════════════════════════════════════════

def inject_unregistered_primitive(rendered):
    """Inject an unregistered table name into rendered nftables output.

    Adds 'inet evil_table' as a table name in one node's exec commands.
    Returns the modified rendered dict (deep copy).
    """
    import copy
    seeded = copy.deepcopy(rendered)

    topo = seeded.setdefault("topology", {})
    nodes = topo.setdefault("nodes", {})

    # Find the first node with exec commands and inject the unregistered table
    injected = False
    for node_name, node_def in nodes.items():
        if not isinstance(node_def, dict):
            continue
        exec_cmds = node_def.get("exec", [])
        if not isinstance(exec_cmds, list) or not exec_cmds:
            continue
        # Inject a fake nft add table command for an unregistered table
        evil_cmd = "nft add table inet evil_table"
        node_def["exec"] = list(exec_cmds) + [evil_cmd]
        injected = True
        break

    if not injected:
        raise RuntimeError("No node with exec commands found for seeded negative injection")

    return seeded


# ═══════════════════════════════════════════════════════════════════════════════
# 6. Main test
# ═══════════════════════════════════════════════════════════════════════════════

solver_json = make_solver_json()

# Write solver JSON to temp file and render
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

# Extract nftables commands from rendered output
nft_commands = extract_nft_commands(rendered)
print(f"Extracted {len(nft_commands)} nftables command(s) from rendered topology")
for i, cmd in enumerate(nft_commands):
    print(f"  [{i}] {cmd[:120]}{'...' if len(cmd) > 120 else ''}")
print()

# Parse primitives
primitives = parse_nft_primitives(nft_commands)

# Check against registry
violations, report = check_primitives(primitives)
print("Primitive source-binding check:")
for line in report:
    print(line)
print()

# ── Positive check: all primitives must be registered ──
if violations:
    print(f"FAIL: {len(violations)} unregistered nftables primitive(s) found:")
    for category, value in violations:
        print(f"  {unregistered_report(category, value)}")
    sys.exit(1)

print("PASS: All nftables primitives are registered in the platform-native registry")
print()

# ── Seeded negative case ──
print("--- Seeded negative case ---")
seeded_rendered = inject_unregistered_primitive(rendered)

seeded_nft_commands = extract_nft_commands(seeded_rendered)
print(f"Seeded output: {len(seeded_nft_commands)} nftables command(s) (includes injected 'evil_table')")

seeded_primitives = parse_nft_primitives(seeded_nft_commands)
seeded_violations, seeded_report = check_primitives(seeded_primitives)

# Verify "inet evil_table" is flagged as unregistered
evil_violations = [(c, v) for c, v in seeded_violations if v == "evil_table" or c == "tables" and "evil_table" in v]

if not evil_violations:
    print("FAIL: CHECKER DID NOT DETECT UNREGISTERED TABLE 'inet evil_table'")
    print("  The seeded negative primitive was NOT flagged as unregistered.")
    print("  This means the checker would accept unregistered primitives in production.")
    sys.exit(1)

print(f"SEEDED NEGATIVE PASS: checker correctly flags 'inet evil_table' as unregistered")
for category, value in evil_violations:
    print(f"  {unregistered_report(category, value)}")
print()

print("PASS fs310-sms050-nftables-primitive-source-binding")
PY
