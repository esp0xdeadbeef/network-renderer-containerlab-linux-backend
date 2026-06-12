#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-210
# Renderer Route-Table Allocation Contract Construction Test
#
# Proves: CLAB renderer routing modules do not supply hardcoded route table
# ID bases, priority bases, BGP health-check targets, or WAN-uplink fallback
# names without CPM authority or documented platform constants.
#
# Covers:
#   1. linux_policy_routes.py: table/priority bases documented as CPM_GAP
#   2. linux_bgp_state.py: no more `return "1.1.1.1"`
#   3. interface_tags.py: no more `or ["wan"]`
#   4. onlink: documented as platform constant
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import re
import sys
from pathlib import Path

repo = Path(".")
failures = 0

# ── 1. Policy route table/priority bases: CPM_GAP documented ────────
print("=== Check 1: table/priority bases CPM_GAP ===")
policy_file = repo / "clabgen/s88/CM/linux_policy_routes.py"
content = policy_file.read_text()

# Must have CPM_GAP comment near table_id = 1000 + slot
gap_pattern = re.compile(r"CPM_GAP.*table base.*1000|CPM_GAP.*priority base.*10000", re.IGNORECASE)
if gap_pattern.search(content):
    print("  PASS: CPM_GAP comment present for table/priority bases")
else:
    print("  FAIL: missing CPM_GAP comment for table/priority bases")
    failures += 1

# Must still use table_id = 1000 + slot (platform constant, not removed)
assert "table_id = 1000 + slot" in content, "table_id expression missing"
assert "priority = 10000 + slot" in content, "priority expression missing"
print("  PASS: table_id/priority expressions preserved with CPM_GAP")

# ── 2. BGP health check: no 1.1.1.1 fallback ────────────────────────
print("\n=== Check 2: BGP health check ===")
bgp_file = repo / "clabgen/s88/CM/linux_bgp_state.py"
bgp_content = bgp_file.read_text()

if 'return "1.1.1.1"' in bgp_content:
    print("  FAIL: hardcoded 1.1.1.1 still present in linux_bgp_state.py")
    failures += 1
else:
    print("  PASS: no hardcoded 1.1.1.1 fallback")

# Must have ValueError instead
assert "ValueError" in bgp_content and "health check" in bgp_content.lower(), \
    "BGP health check should raise ValueError with diagnostic"
print("  PASS: ValueError diagnostic present for missing candidates")

# CPM_GAP comment present
assert "CPM_GAP" in bgp_content, "BGP file should have CPM_GAP comment"
print("  PASS: CPM_GAP documented for health check target")

# ── 3. Interface tags: no `or ["wan"]` fallback ──────────────────────
print("\n=== Check 3: interface tags WAN uplink fallback ===")
tags_file = repo / "clabgen/s88/site/interface_tags.py"
tags_content = tags_file.read_text()

# The old pattern `or ["wan"]` must not exist
if 'or ["wan"]' in tags_content:
    print('  FAIL: hardcoded `or ["wan"]` still present')
    failures += 1
else:
    print('  PASS: no `or ["wan"]` fallback')

# Must use explicitWan from CPM
assert "explicitWan" in tags_content, \
    "interface_tags should check explicitWan from CPM"
print("  PASS: explicitWan check present")

# ── 4. onlink: documented as platform constant ──────────────────────
print("\n=== Check 4: onlink flag ===")
route_files = list(repo.glob("clabgen/s88/CM/linux_*routes*.py"))
onlink_count = 0
for rf in route_files:
    rc = rf.read_text()
    onlink_count += rc.count("onlink")

# onlink is used (platform constant for Containerlab bridge topology)
assert onlink_count > 0, "onlink should be present as platform constant"
print(f"  PASS: {onlink_count} onlink usages — deterministic platform constant")

# ── Summary ──────────────────────────────────────────────────────────
print(f"\n{'PASS' if failures == 0 else 'FAIL'} FS-310-HDS-010-SDS-010-SMS-210: "
      f"{failures} violation(s)")
sys.exit(0 if failures == 0 else 1)
PY
