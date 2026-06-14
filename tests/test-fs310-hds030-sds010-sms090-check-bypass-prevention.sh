#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# FS-310-HDS-030-SDS-010-SMS-090: Renderer Check Bypass Prevention
# Seeded bypass examples that MUST be caught. If any seeded pattern passes
# the checker, the checker is broken and the test must fail.

python3 - <<'PY'
import ast
import re
import sys
from pathlib import Path

repo = Path(".")

# ── Seeded bypass patterns that MUST NOT appear ──────────────────────

# Pattern 1: Character-list literal bypass
#   'a' 'c' 'c' 'e' 's' 's' would let "access" pass a literal scan
char_list_pattern = re.compile(
    r"'(?:\w|\\[nrt])'\s*'\s*(?:\w|\\[nrt])'\s*'\s*(?:\w|\\[nrt])'"
)

# Pattern 2: String concatenation to split a keyword
#   "ip" + " route" would pass a naive grep for "ip route"
split_concat_pattern = re.compile(
    r'"(?:ip|nft)\w*"\s*\+\s*"(?:\s*\w+)"'
)

# Pattern 3: Dynamic command construction via eval/exec/compile
dynamic_pattern = re.compile(
    r'\b(?:eval|exec|compile)\s*\('
)

# Pattern 4: base64 or hex encoding to hide a literal
encoding_pattern = re.compile(
    r'\b(?:b64decode|b64encode|fromhex|unhexlify|base64\.b64)\b'
)

# Pattern 5: Broad ignore on test assertions (catch-all except)
broad_ignore_pattern = re.compile(
    r'except\s*:'
)

# Pattern 6: Test-only allowlist that skips validation
allowlist_pattern = re.compile(
    r'(?:ALLOWLIST|WHITELIST|ALLOW_FORBIDDEN|SKIP_CHECK)\s*='
)

violations = []

# Scan Python source files in clabgen/
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    text = py_file.read_text(encoding="utf-8")

    for lineno, line in enumerate(text.splitlines(), start=1):
        if char_list_pattern.search(line):
            violations.append(
                f"CHAR_LIST_BYPASS {py_file}:{lineno}: {line.strip()[:80]}"
            )
        if split_concat_pattern.search(line):
            violations.append(
                f"SPLIT_CONCAT_BYPASS {py_file}:{lineno}: {line.strip()[:80]}"
            )
        if dynamic_pattern.search(line):
            # Allow eval/exec in comments or docstrings
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith('"') or stripped.startswith("'"):
                continue
            violations.append(
                f"DYNAMIC_CODE {py_file}:{lineno}: {line.strip()[:80]}"
            )
        if encoding_pattern.search(line):
            violations.append(
                f"ENCODING_BYPASS {py_file}:{lineno}: {line.strip()[:80]}"
            )

# Scan shell test files
for sh_file in sorted(repo.glob("tests/*.sh")):
    text = sh_file.read_text(encoding="utf-8")

    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if broad_ignore_pattern.search(line):
            violations.append(
                f"BROAD_EXCEPT {sh_file}:{lineno}: {line.strip()[:80]}"
            )
        if allowlist_pattern.search(line):
            violations.append(
                f"ALLOWLIST {sh_file}:{lineno}: {line.strip()[:80]}"
            )

# Also scan host-module.nix for shell fallback patterns
host_module = repo / "host-module.nix"
if host_module.exists():
    text = host_module.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        if allowlist_pattern.search(line):
            violations.append(
                f"ALLOWLIST {host_module}:{lineno}: {line.strip()[:80]}"
            )

if violations:
    print(f"FAIL fs310-hds010-sds010-sms090-check-bypass-prevention: {len(violations)} violation(s)")
    for v in violations:
        print(f"  {v}")
    sys.exit(1)

# ── Positive check: verifies the checker itself catches a seeded bypass ──
# If this assertion passes, the bypass would go undetected — the checker works.
# We prove this by checking that a deliberate bypass WOULD be caught.
test_input = "'a' 'c' 'c' 'e' 's' 's'"
assert char_list_pattern.search(test_input), \
    "SEEDED_BYPASS_NOT_CAUGHT: char-list pattern must match seeded bypass"
test_input2 = '"ip" + " route"'
assert split_concat_pattern.search(test_input2), \
    "SEEDED_BYPASS_NOT_CAUGHT: split-concat pattern must match seeded bypass"

print("PASS fs310-hds010-sds010-sms090-check-bypass-prevention")
PY
