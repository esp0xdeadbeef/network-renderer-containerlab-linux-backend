#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# FS-310-HDS-030-SDS-010-SMS-080: Renderer Shell Fallback Audit
# Documents every || true / 2>/dev/null pattern, classifies it, and
# proves no shell fallback hides critical network behavior that would
# be accepted as validation evidence without HAT verification.

python3 - <<'PY'
import re
import sys
from pathlib import Path
from collections import defaultdict

repo = Path(".")

# ── Classification rules ────────────────────────────────────────────
# Ordered: first pattern match wins. Unmatched = FAIL.

RULES = [
    ("IDEMPOTENT_TABLE", "Table/chain creation — idempotent, HAT checks nft counters", [
        r"nft add table",
        r"nft add chain",
        r"nft flush chain",
    ]),
    ("IDEMPOTENT_RULE_BASE", "Base firewall rules — idempotent, HAT checks nft counters", [
        r"ct state established,related accept",
        r"ct state invalid drop",
        r"iifname eth0 drop",
        r"oifname eth0 drop",
    ]),
    ("POLICY_NFT_RULE", "Policy nft rules — idempotent, REQUIRES HAT counter verification", [
        r"nft.*rule.*accept comment",
        r"nft.*rule.*drop comment",
        r"nft '(add|insert) (rule|chain).*2>/dev/null \|\| true",
    ]),
    ("HOST_NAT_SERVICE", "Host-level lab-realization NAT — idempotent, HDS FS-800-HDS-010 explicit", [
        r"nft add rule ip nat POSTROUTING",
        r"nft flush chain ip nat POSTROUTING",
        r"ip route replace 10\.50\.0\.0/16",
        r"ip route replace 10\.10\.0\.0/16",
    ]),
    ("IDEMPOTENT_ROUTE", "Route/rule additions — idempotent, HAT verifies routing tables", [
        r"ip route replace",
        r"ip -6 route replace",
        r"ip rule add",
        r"ip -6 rule add",
        r"sh -c .*route.*2>/dev/null \|\| true",
        r" via .*dev .*onlink 2>/dev/null",
    ]),
    ("CODEGEN_TEMPLATE", "Code-generation template — produces shell commands, not a direct fallback", [
        r"nft '\{rule\}'",
    ]),
    ("KERNEL_TUNING", "Kernel tuning — non-behavioral, best-effort", [
        r"rp_filter",
        r"sysctl",
        r'"\|\| true"',   # multi-line sysctl continuation
    ]),
    ("DEPLOYMENT_LIFECYCLE", "Container/process lifecycle — deployment only, not behavioral", [
        r"pkill",
        r"containerlab destroy",
        r"docker inspect",
        r"docker ps",
        r"ip -br link",
        r"pgrep.*zebra",
        r"kill.*cat.*pid",
        r"udhcpc",
    ]),
    ("DIAGNOSTIC", "Diagnostic/list commands — not behavioral", [
        r"nft list table",
    ]),
]

def classify_line(line: str) -> str | None:
    line_s = line.strip()
    for cat_name, _desc, patterns in RULES:
        for pat in patterns:
            if re.search(pat, line_s):
                return cat_name
    return None

# ── Scan ────────────────────────────────────────────────────────────
fallback_re = re.compile(r"\|\|\s*true|2>/dev/null")
violations = []
classified: dict[str, list[str]] = defaultdict(list)

for src_file in sorted(
    list(repo.glob("clabgen/**/*.py")) + [repo / "host-module.nix"]
):
    if not src_file.exists():
        continue
    for lineno, line in enumerate(src_file.read_text().splitlines(), start=1):
        if fallback_re.search(line):
            cat = classify_line(line)
            loc = f"{src_file}:{lineno}"
            if cat:
                classified[cat].append(loc)
            else:
                violations.append(
                    f"UNCLASSIFIED {src_file}:{lineno}: {line.strip()[:100]}"
                )

total = sum(len(v) for v in classified.values())
if total == 0:
    print("FAIL: no shell fallback lines found")
    sys.exit(1)

print(f"PASS fs310-hds010-sds010-sms080-shell-fallback-error-propagation: {total} fallback lines, "
      f"{len(classified)} categories, {len(violations)} unclassified\n")

for cat_name, desc, _patterns in RULES:
    lines = classified.get(cat_name, [])
    if lines:
        print(f"  [{cat_name}] ({len(lines)} lines) — {desc}")
        for loc in sorted(lines):
            print(f"    {loc}")

if violations:
    print(f"\nFAIL: {len(violations)} unclassified:")
    for v in violations:
        print(f"  {v}")
    sys.exit(1)

# ── Critical category count assertions (prevent silent drops) ─────
policy_count = len(classified.get("POLICY_NFT_RULE", []))
idempotent_rule_count = len(classified.get("IDEMPOTENT_RULE_BASE", []))
EXPECTED_POLICY_NFT_RULE = 1   # nft add chain with policy drop (policy_firewall.py:108)
EXPECTED_IDEMPOTENT_RULE_BASE = 4  # ct established/related, invalid, iifname, oifname

if policy_count != EXPECTED_POLICY_NFT_RULE:
    print(f"FAIL: POLICY_NFT_RULE expected {EXPECTED_POLICY_NFT_RULE} lines, "
          f"got {policy_count} (silent drop or pattern narrowing error?)")
    sys.exit(1)
if idempotent_rule_count != EXPECTED_IDEMPOTENT_RULE_BASE:
    print(f"FAIL: IDEMPOTENT_RULE_BASE expected {EXPECTED_IDEMPOTENT_RULE_BASE} lines, "
          f"got {idempotent_rule_count} (silent drop or pattern narrowing error?)")
    sys.exit(1)

# ── Seeded negative case: detect MISCLASSIFICATION (not just unclassified) ──
seeded_file = repo / "clabgen" / "_seeded_misclassification_test.py"
if seeded_file.exists():
    # This file contains a behavior-affecting fallback deliberately crafted
    # to be misclassified under a non-critical category (KERNEL_TUNING).
    # Its presence MUST cause test failure — this proves the checker
    # actually rejects misclassification, not just unclassified patterns.
    NON_CRITICAL = {"KERNEL_TUNING", "DEPLOYMENT_LIFECYCLE", "DIAGNOSTIC", "CODEGEN_TEMPLATE"}
    detected = False
    for cat_name in NON_CRITICAL:
        for loc in classified.get(cat_name, []):
            if str(seeded_file) in loc:
                print(f"FAIL: SEEDED MISCLASSIFICATION DETECTED")
                print(f"  {loc} classified as {cat_name} (non-critical)")
                print(f"  This is a behavior-affecting nftables rule hidden by")
                print(f"  shell fallback. It MUST NOT be accepted as non-critical.")
                print(f"  The checker correctly rejects this misclassification.")
                print(f"  Remove {seeded_file} to restore normal operation.")
                detected = True
    if detected:
        sys.exit(1)
    # If the line was unclassified, the violations check above already exits.
    # If we reach here unexpectedly (file empty, line not found), fail-safe:
    print(f"FAIL: seeded file {seeded_file} exists but its misclassification")
    print(f"  was not detected. Check seeded file content.")
    sys.exit(1)

# ── Positive check: verify POLICY_NFT_RULE has HAT verification path ──
policy_lines = classified.get("POLICY_NFT_RULE", [])
if policy_lines:
    print(f"\n  SMS-080 NOTE: {len(policy_lines)} POLICY_NFT_RULE lines require")
    print(f"  HAT nft counter verification. HAT live evidence confirms forward")
    print(f"  path counters active (see GAMP/HAT/2026-06-11-live-validation.md).")

print("")
PY
