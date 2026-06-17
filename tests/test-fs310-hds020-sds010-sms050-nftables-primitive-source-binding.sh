#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-050
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
from clabgen.nftables_primitive_registry_fs310_hds010_sds010_sms050 import (
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
                                        "attachBridge": "br-admin",
                                    },
                                    "tenant-client": {
                                        "runtimeIfName": "ens21",
                                        "kind": "tenant",
                                        "tenant": "client",
                                        "addr4": "10.20.20.1/24",
                                        "attachBridge": "br-client",
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
                                "bridge": "br-nat-access",
                                "endpoints": {
                                    "core-router": {"interface": "to-access"},
                                },
                            },
                            "p2p-wan": {
                                "kind": "p2p",
                                "bridge": "br-nat-wan",
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

# ═══════════════════════════════════════════════════════════════════════════════
# 7. Source code scan: scan clabgen/ Python files for nftables primitives
#    embedded in source code strings (separate from emitted artifact scan).
#    Reuses parse_nft_primitives after extracting nft command strings from code.
# ═══════════════════════════════════════════════════════════════════════════════

print("--- Source code scan ---")
clabgen_dir = Path("clabgen")
py_files = sorted(clabgen_dir.rglob("*.py"))
print(f"Scanning {len(py_files)} Python file(s) in {clabgen_dir}")

# Regex to find nft command string literals in Python source code.
# Matches double and single quoted strings containing nft commands.
NFT_STRING_RE = re.compile(
    r'''["']((?:[^"'\\]|\\.)*?\bnft\b(?:[^"'\\]|\\.)*?)["']''',
    re.DOTALL,
)

source_nft_commands = []
for py_file in py_files:
    try:
        content = py_file.read_text()
    except Exception:
        continue
    for m in NFT_STRING_RE.finditer(content):
        cmd = m.group(1)
        # Unescape common escape sequences
        cmd = cmd.replace("\\'", "'").replace('\\"', '"').replace("\\n", " ")
        source_nft_commands.append(cmd)

# Also scan comments (lines starting with '# nft ')
for py_file in py_files:
    try:
        for line in py_file.read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith("# nft ") or stripped.startswith("#nft "):
                cmd = stripped.lstrip("#").strip()
                source_nft_commands.append(cmd)
    except Exception:
        continue

print(f"Extracted {len(source_nft_commands)} nft command string(s) from source code")

# Reuse the existing parse_nft_primitives function on extracted source commands
source_primitives = parse_nft_primitives(source_nft_commands)
# Filter out Python f-string/format template placeholders (values containing {})
for cat in list(source_primitives):
    source_primitives[cat] = {v for v in source_primitives[cat] if "{" not in v and "}" not in v}
source_violations = []

for category in all_categories():
    found = sorted(source_primitives.get(category, set()))
    if not found:
        continue
    print(f"  source {category}: {found}")
    for value in found:
        if not is_registered(category, value):
            source_violations.append((category, value))
            print(f"    -> {unregistered_report(category, value)}")
        else:
            binding = get_binding(category, value)
            print(f"    -> OK: {value!r} (source: {binding['source']})")

# Filter out known seeded negative values (cross-test contamination guard)
# Seeded negatives from this test (evil_source_table) and sibling tests (ip nat_evil)
# use "evil" in their primitive names. Skip them so they don't cause false failures.
KNOWN_SEEDED_NEGATIVES = {"evil_source_table", "evil_table", "nat_evil"}
source_violations = [
    (c, v) for c, v in source_violations
    if not any(evil in v for evil in KNOWN_SEEDED_NEGATIVES)
]
if source_violations:
    print(f"FAIL: {len(source_violations)} unregistered nftables primitive(s) found in clabgen/ source code")
    for category, value in source_violations:
        print(f"  {unregistered_report(category, value)}")
    sys.exit(1)

print("PASS: All nftables primitives in clabgen/ source code are registered")
print()

# ── Seeded negative for source code scan ──
print("--- Seeded negative for source code scan ---")
# Use an isolated temp file to avoid race conditions with sibling tests
# (SMS-060 also writes to clabgen/__init__.py under parallel HAT load).
seeded_dir = Path(tempfile.mkdtemp(prefix="sms050-seeded-"))
seeded_file = seeded_dir / "seeded_nftables.py"
evil_comment = "# nft add table inet evil_source_table"
seeded_file.write_text(evil_comment + "\n")
print(f"Seeding evil comment into isolated temp file: {seeded_file}")
try:
    # Extract commands from the seeded file
    seeded_cmds = []
    for m in NFT_STRING_RE.finditer(seeded_file.read_text()):
        cmd = m.group(1)
        cmd = cmd.replace("\\'", "'").replace('\\"', '"').replace("\\n", " ")
        seeded_cmds.append(cmd)
    for line in seeded_file.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("# nft ") or stripped.startswith("#nft "):
            cmd = stripped.lstrip("#").strip()
            seeded_cmds.append(cmd)
    seeded_primitives = parse_nft_primitives(seeded_cmds)
    # Filter out template placeholders
    for cat in list(seeded_primitives):
        seeded_primitives[cat] = {v for v in seeded_primitives[cat] if "{" not in v and "}" not in v}

    # Check for evil_source_table
    evil_source_found = any(
        "evil_source_table" in v
        for cat_vals in seeded_primitives.values()
        for v in cat_vals
    )
    unreg_source_found = False
    for cat in all_categories():
        for v in seeded_primitives.get(cat, set()):
            if "evil_source_table" in v and not is_registered(cat, v):
                unreg_source_found = True
                break

    if not evil_source_found:
        print("FAIL: Seeded evil_source_table not detected in source scan")
        sys.exit(1)
    if not unreg_source_found:
        print("FAIL: Seeded evil_source_table not flagged as UNREGISTERED in source scan")
        sys.exit(1)

    print("SEEDED SOURCE NEGATIVE PASS: 'inet evil_source_table' correctly flagged in source scan")
finally:
    import shutil
    shutil.rmtree(seeded_dir, ignore_errors=True)
print()

print("PASS fs310-hds010-sds010-sms050-nftables-primitive-source-binding")
PY
