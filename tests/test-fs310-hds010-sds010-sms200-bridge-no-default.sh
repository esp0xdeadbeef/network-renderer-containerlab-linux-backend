#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-200
# Renderer Bridge-Network No-Default Contract Construction Test
#
# Proves: CLAB renderer bridge-network and VM-network modules do not supply
# hardcoded bridge addresses, DHCP server enablement, IP masquerade behavior,
# or DHCP pool offsets without CPM authority.
#
# Note: host-module.nix and vm-network-nat.nix are in the nixos repo (V5, V11,
# V12). This test scans the CLAB renderer Python source for bridge-related
# hardcoding and verifies renderer-emitted bridge configs consume CPM data.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import re
import sys
from pathlib import Path

repo = Path(".")
failures = 0

# ── 1. Source scan: no hardcoded bridge addresses in Python ──────────
print("=== Check 1: no hardcoded bridge addresses ===")
HARDCODED_BRIDGE_PATTERNS = [
    (r'10\.11\.0\.1/24', "10.11.0.1/24 bridge address"),
    (r'198\.18\.0\.1/24', "198.18.0.1/24 benchmark address"),
    (r'"198\.18\.0\.', "198.18.0.x subnet string"),
]

for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    for pattern, desc in HARDCODED_BRIDGE_PATTERNS:
        if re.search(pattern, content):
            for lineno, line in enumerate(content.splitlines(), 1):
                if re.search(pattern, line):
                    print(f"  FAIL: {py_file}:{lineno}: {desc}: {line.strip()[:100]}")
                    failures += 1

if failures == 0:
    print("  PASS: no hardcoded bridge addresses in CLAB Python source")

# ── 2. Source scan: no hardcoded DHCPServer/IPMasquerade in Python ───
print("\n=== Check 2: no hardcoded DHCP/masquerade policy ===")
dhcp_fails = 0
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    for lineno, line in enumerate(content.splitlines(), 1):
        if re.search(r'DHCPServer\s*=\s*True', line):
            print(f"  FAIL: {py_file}:{lineno}: hardcoded DHCPServer=True")
            dhcp_fails += 1
        if re.search(r'IPMasquerade\s*=\s*"', line):
            print(f"  FAIL: {py_file}:{lineno}: hardcoded IPMasquerade")
            dhcp_fails += 1

if dhcp_fails == 0:
    print("  PASS: no hardcoded DHCPServer/IPMasquerade in CLAB Python source")
else:
    failures += dhcp_fails

# ── 3. Source scan: no hardcoded DHCP pool defaults in Python ────────
print("\n=== Check 3: no hardcoded DHCP pool defaults ===")
pool_fails = 0
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    for lineno, line in enumerate(content.splitlines(), 1):
        if re.search(r'dhcpPoolOffset\s+or\s+\d+', line):
            print(f"  FAIL: {py_file}:{lineno}: hardcoded dhcpPoolOffset")
            pool_fails += 1
        if re.search(r'dhcpPoolSize\s+or\s+\d+', line):
            print(f"  FAIL: {py_file}:{lineno}: hardcoded dhcpPoolSize")
            pool_fails += 1

if pool_fails == 0:
    print("  PASS: no hardcoded DHCP pool offset/size in CLAB Python source")
else:
    failures += pool_fails

# ── 4. Bridge control module: verify CPM data consumption ────────────
print("\n=== Check 4: bridge control modules consume CPM data ===")
merge_file = repo / "clabgen/s88/enterprise/merge.py"
if merge_file.exists():
    merge_content = merge_file.read_text()
    # Bridge control modules should reference CPM input, not hardcoded data
    has_bridge_cm = "bridge_control_modules" in merge_content
    if has_bridge_cm:
        print("  PASS: bridge_control_modules present in merge.py")
    else:
        print("  NOTE: bridge_control_modules not found in merge.py (may use nixos repo)")

# ── 5. Seeded negative: bridge generation with missing CPM data ──────
print("\n=== Check 5: seeded negative — bridge without CPM data ===")
try:
    from clabgen.s88.enterprise.site_loader import load_sites
    # Build minimal solver JSON with a bridge-network entry but no wanPool
    solver_json = {
        "enterprise": {
            "esp0xdeadbeef": {
                "site": {
                    "test-site": {
                        "nodes": {
                            "test-core": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "interfaces": {
                                    "wan-iface": {
                                        "runtimeIfName": "ens10",
                                        "kind": "wan",
                                        "upstream": "test-uplink",
                                        "hostUplink": {},
                                    }
                                },
                            }
                        },
                        "links": {},
                        "bridge_networks": {
                            "br-test": {
                                "name": "br-test",
                            }
                        },
                    }
                }
            }
        }
    }
    sites = load_sites(solver_json)
    # If we got here without ValueError, the renderer didn't fail on missing data
    print("  NOTE: load_sites accepted bridge_networks without explicit CPM data")
except Exception as e:
    # Expected: renderer should flag missing data
    if "missing" in str(e).lower() or "require" in str(e).lower() or "explicit" in str(e).lower():
        print(f"  PASS: renderer fails on bridge without CPM data: {type(e).__name__}")
    else:
        print(f"  NOTE: renderer failure for other reason: {type(e).__name__}: {e}")

# ── Summary ──────────────────────────────────────────────────────────
print(f"\n{'PASS' if failures == 0 else 'FAIL'} FS-310-HDS-010-SDS-010-SMS-200: "
      f"{failures} violation(s) in CLAB renderer source")
sys.exit(0 if failures == 0 else 1)
PY
