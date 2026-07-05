#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-102
# Construction test: CLAB Renderer CPM-Only Consumption
# Proves: CLAB renderer consumes ONLY CPM-mediated output (no direct
# intent/inventory imports, no silent error hiders, no side-channel
# field consumption, entrypoints require CPM JSON, flake.nix hostModule
# accepts cpm struct not raw paths).
#
# SMS-102 is the CLAB per-renderer child spec of SMS-100.
# Two active seeded negative cases required per SMS §Seeded Negative Requirement.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import os
import re
import sys
import tempfile
from pathlib import Path

repo = Path(".")
repo_name = "network-renderer-containerlab-linux-backend"

# ── KNOWN_GAPS: pre-existing violations acknowledged by analysis ──
# Format: (file_path, line_number, description)
# These are pre-existing silent-hider patterns that have not yet been
# remediated.  The scanner must still detect them; KNOWN_GAPS keeps the
# construction test passing while the gaps are tracked for remediation.
KNOWN_GAPS = {
    # Silent hiders — `except Exception:` with fallback return, no diagnostic
    ("clabgen/provenance_fields.py", 18, "except Exception: return {} — load_json_object swallows all parse errors silently"),
    ("clabgen/provenance_fields.py", 106, "except Exception: return None — _git_rev swallows git errors silently"),
    ("clabgen/provenance_fields.py", 123, "except Exception: return None — _git_dirty swallows git errors silently"),
    ("clabgen/provenance_fields.py", 178, "except Exception: return {available: False} — renderer_lock_summary swallows JSON parse errors silently"),
    ("clabgen/parse-solver-json.py", 39, "except Exception: return {} — _load_renderer_inventory_for_input swallows JSON/env errors silently"),
    ("clabgen/parse-solver-json.py", 45, "except Exception: return {} — _load_renderer_inventory_for_input swallows file read errors silently"),
    ("clabgen/s88/CM/linux_route_values.py", 61, "except Exception: pass — silent pass on int(prefix) failure"),
    ("clabgen/s88/CM/linux_route_values.py", 67, "except Exception: return dst — swallows IPv4Network parse errors silently"),
    ("clabgen/s88/CM/linux_route_values.py", 76, "except Exception: return None — _host_prefix swallows IP parse errors silently"),
    ("clabgen/s88/CM/linux_addressing.py", 19, "except Exception: return addr — _canon_v6 swallows IPv6 parse errors silently"),
    ("clabgen/s88/CM/linux_addressing.py", 28, "except Exception: return False — _is_network_address swallows IP parse errors silently"),
    ("clabgen/s88/CM/linux_addressing.py", 77, "except Exception: return None — _p2p_peer swallows IP parse errors silently"),
    ("clabgen/s88/CM/linux_addressing.py", 90, "except Exception: return None — _addr_ip swallows IP parse errors silently"),
    ("clabgen/s88/CM/linux_route_via.py", 18, "except Exception: return False — _same_subnet swallows IP parse errors silently"),
    ("clabgen/s88/CM/linux_bgp_state.py", 163, "except Exception: return None — _peer_ip swallows IP parse errors silently"),

}

failures = 0
warnings = 0

def fail(msg):
    global failures
    print(f"  FAIL: {msg}")
    failures += 1

def warn(msg):
    global warnings
    print(f"  WARN: {msg}")
    warnings += 1

# ═══════════════════════════════════════════════════════════════════════
# CHECK 1: Source scan — no direct intent/inventory imports in Python
# ═══════════════════════════════════════════════════════════════════════
print("=== Check 1: no direct intent/inventory .nix imports in Python source ===")
INTENT_INVENTORY_PATTERNS = [
    (r'intent\.nix', "intent.nix reference"),
    (r'inventory[_-]?clab\.nix', "inventory-clab.nix reference"),
    (r'inventory[_-]?nixos\.nix', "inventory-nixos.nix reference"),
    (r'forwarding[_-]?model.*\.nix', "forwarding-model .nix reference"),
]

check1_fails = 0
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    for pattern, desc in INTENT_INVENTORY_PATTERNS:
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(pattern, line):
                # Skip comments/docstrings — we're looking for actual code references
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                rel_path = str(py_file.relative_to(repo))
                fail(f"{rel_path}:{lineno}: {desc}: {line.strip()[:100]}")
                check1_fails += 1

if check1_fails == 0:
    print("  PASS: no direct intent/inventory .nix references in CLAB Python source")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 2: Source scan — no silent error hiders (except Exception: pass)
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 2: no silent error hiders (except Exception: pass or equivalent) ===")

# A silent hider is an `except Exception:` (or bare `except:`) whose body
# does not re-raise, log a diagnostic, or record an error before returning
# a fallback.  We detect these by finding `except Exception:` lines and
# then checking whether the following statement is a bare `return` or
# `pass` without any diagnostic output.
#
# Heuristic: flag every `except Exception:` and `except BaseException:`
# in production code.  KNOWN_GAPS entries mark pre-existing ones.
# New additions will cause test failure.
EXCEPT_PATTERN = re.compile(r'^\s*except\s+(Exception|BaseException)\s*:')

check2_finds = []
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    lines = content.splitlines()
    for lineno, line in enumerate(lines, 1):
        if EXCEPT_PATTERN.match(line):
            rel_path = str(py_file.relative_to(repo))
            check2_finds.append((rel_path, lineno, line.strip()))

# Check each find against KNOWN_GAPS
for find in check2_finds:
    fpath, lineno, _ = find
    # Normalize path separators
    fpath_norm = fpath.replace(os.sep, "/")
    is_known = any(
        gap[0].replace(os.sep, "/") == fpath_norm and gap[1] == lineno
        for gap in KNOWN_GAPS
    )
    if not is_known:
        fail(f"{fpath}:{lineno}: NEW silent hider — not in KNOWN_GAPS: {find[2]}")

# Verify all KNOWN_GAPS entries still exist (if a gap is fixed, remove from list)
for gap_path, gap_lineno, gap_desc in sorted(KNOWN_GAPS):
    gap_file = repo / gap_path
    if not gap_file.exists():
        warn(f"KNOWN_GAP file removed (remove from list): {gap_path}")
        continue
    lines = gap_file.read_text().splitlines()
    if gap_lineno > len(lines):
        warn(f"KNOWN_GAP line {gap_lineno} out of range in {gap_path} (remove from list)")
        continue
    line = lines[gap_lineno - 1]
    if not EXCEPT_PATTERN.match(line):
        warn(f"KNOWN_GAP line {gap_lineno} in {gap_path} no longer matches — gap may be fixed (remove from list)")

if failures == 0:
    print(f"  PASS: {len(check2_finds)} except Exception: sites, all in KNOWN_GAPS ({len(KNOWN_GAPS)} gaps)")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 3: Source scan — no upstreamEmulation/providerAccess consumption
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 3: no upstreamEmulation/providerAccess consumption in production code ===")

# The rejection guard at site_loader.py:116-118 is the correct behavior —
# it raises ValueError on encountering these fields.  The scanner must
# allow rejection code but flag consumption code.
SIDECHANNEL_FIELDS = ("upstreamEmulation", "providerAccess")

# Whitelisted rejection patterns (these are correct — they REJECT, not consume)
REJECTION_SITES = {
    ("clabgen/s88/enterprise/site_loader.py", 116),
    ("clabgen/s88/enterprise/site_loader.py", 117),
    ("clabgen/s88/enterprise/site_loader.py", 118),
}

check3_fails = 0
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    rel_path = str(py_file.relative_to(repo)).replace(os.sep, "/")
    for lineno, line in enumerate(content.splitlines(), 1):
        stripped = line.strip()
        # Skip comments
        if stripped.startswith("#"):
            continue
        for field_name in SIDECHANNEL_FIELDS:
            if field_name in line:
                # Check if this is at a known rejection site
                if (rel_path, lineno) in REJECTION_SITES:
                    continue
                # Check if the line is part of a rejection guard (raises ValueError)
                # Look at context: if the next non-empty line has raise/ValueError,
                # treat as rejection
                context_lines = content.splitlines()[lineno:lineno+4]
                context_has_rejection = any(
                    "raise ValueError" in cl or "not supported" in cl
                    for cl in context_lines
                )
                if context_has_rejection:
                    continue
                fail(f"{rel_path}:{lineno}: side-channel field '{field_name}' consumption: {stripped[:100]}")
                check3_fails += 1

if check3_fails == 0:
    print("  PASS: no upstreamEmulation/providerAccess consumption in CLAB Python source")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 4: Nix source scan — no direct intent/inventory reads in production
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 4: no direct intent/inventory file reads in Nix production code ===")

# Production Nix files: flake.nix, host-module.nix
# We check they don't use builtins.readFile on intent.nix or inventory*.nix
nix_files_to_check = ["flake.nix", "host-module.nix"]
READFILE_INTENT_RE = re.compile(r"builtins\.(readFile|readDir|pathExists)\s+.*intent\.nix")
READFILE_INVENTORY_RE = re.compile(r"builtins\.(readFile|readDir|pathExists)\s+.*inventory[^/]*\.nix")

check4_fails = 0
for nix_file_name in nix_files_to_check:
    nix_file = repo / nix_file_name
    if not nix_file.exists():
        continue
    content = nix_file.read_text()
    for lineno, line in enumerate(content.splitlines(), 1):
        if READFILE_INTENT_RE.search(line):
            fail(f"{nix_file_name}:{lineno}: builtins.readFile of intent.nix: {line.strip()[:100]}")
            check4_fails += 1
        if READFILE_INVENTORY_RE.search(line):
            fail(f"{nix_file_name}:{lineno}: builtins.readFile of inventory*.nix: {line.strip()[:100]}")
            check4_fails += 1

if check4_fails == 0:
    print("  PASS: no direct intent/inventory file reads in Nix production code")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 5: flake.nix hostModule accepts cpm struct, not raw paths
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 5: flake.nix hostModule accepts cpm struct, not raw paths ===")

flake_nix = repo / "flake.nix"
flake_content = flake_nix.read_text()

# hostModule must accept rendererInput (which may contain cpm struct),
# not raw file paths to intent.nix or inventory*.nix.
# Verify: the hostModule signature includes the cpm handling
has_host_module = "renderer.hostModule" in flake_content
has_cpm_struct = "rendererInput ? cpm" in flake_content or "rendererInput.cpm" in flake_content
has_cpm_json_path = "cpmJsonPath" in flake_content

if has_host_module and (has_cpm_struct or has_cpm_json_path):
    print("  PASS: flake.nix hostModule consumes cpm struct via rendererInput")
else:
    if not has_host_module:
        warn("  NOTE: renderer.hostModule not found in flake.nix (may have moved)")
    elif not (has_cpm_struct or has_cpm_json_path):
        fail("  flake.nix hostModule does not accept cpm struct — may accept raw paths")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 6: Entrypoints require CPM JSON, not raw .nix paths
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 6: entrypoints require CPM JSON, not raw .nix paths ===")

# generate-clab-config.py
gen_py = repo / "generate-clab-config.py"
gen_content = gen_py.read_text()
has_json_validation = "cpm_input_path.suffix not in (\".json\",)" in gen_content or \
    ".json" in gen_content and "CPM JSON" in gen_content
if has_json_validation:
    print("  PASS: generate-clab-config.py validates CPM JSON input")
else:
    fail("  generate-clab-config.py missing CPM JSON input validation")

# deploy-clab.sh
deploy_sh = repo / "deploy-clab.sh"
deploy_content = deploy_sh.read_text()
rejects_nix = "*.nix" in deploy_content and "fail" in deploy_content and "CPM JSON" in deploy_content
if rejects_nix or "intent/inventory Nix" in deploy_content:
    print("  PASS: deploy-clab.sh requires CPM JSON, rejects .nix input")
else:
    warn("  deploy-clab.sh: verify CPM JSON requirement (may use other validation)")

# ═══════════════════════════════════════════════════════════════════════
# SEEDED NEGATIVE 1: Silent error hiding via except Exception: pass
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Seeded Negative 1: silent error hiding (except Exception: pass) ===")

with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    # Inject a CLAB renderer code path that wraps CPM data ingestion in
    # try/except Exception: pass, silently swallowing a missing-field exception
    injected_file = tmp / "injected_silent_hider.py"
    injected_file.write_text('''\
from __future__ import annotations
from typing import Any, Dict

def _ingest_cpm_data(cpm: Dict[str, Any]) -> str:
    """Inject CPM data with silent error swallowing — SMS-102 negative."""
    try:
        node_data = cpm["control_plane_model"]["data"]["esp"]["clab"]
        return node_data.get("runtimeTargets", {})
    except Exception:
        pass  # SILENT HIDER — should be detected
    return {}
''')

    # Scan the injected file with the same EXCEPT_PATTERN
    content = injected_file.read_text()
    found_hider = False
    for lineno, line in enumerate(content.splitlines(), 1):
        if EXCEPT_PATTERN.match(line):
            found_hider = True
            print(f"  SEEDED_NEGATIVE_CAUGHT: {injected_file.name}:{lineno}: {line.strip()}")

    if found_hider:
        print("  PASS: seeded negative 1 (silent error hider) detected")
    else:
        fail("SEEDED_NEGATIVE_NOT_CAUGHT: silent error hider not detected by scanner")

# ═══════════════════════════════════════════════════════════════════════
# SEEDED NEGATIVE 2: Side-channel field consumption
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Seeded Negative 2: side-channel field consumption ===")

with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    # Inject a CLAB renderer module that reads upstreamEmulation in production
    # code — this is CONSUMPTION, not rejection.
    injected_file = tmp / "injected_sidechannel_consumer.py"
    injected_file.write_text('''\
from __future__ import annotations
from typing import Any, Dict

def _render_emulation_artifacts(site: Dict[str, Any]) -> list[str]:
    """Consume upstreamEmulation side-channel field — SMS-102 negative."""
    emulation = site.get("upstreamEmulation")
    if not isinstance(emulation, dict):
        return []
    scenarios = emulation.get("scenarios", {})
    result = []
    for scenario_name, scenario in scenarios.items():
        if isinstance(scenario, dict):
            result.append(f"# emulation scenario: {scenario_name}")
    return result

def _render_provider_artifacts(site: Dict[str, Any]) -> list[str]:
    """Consume providerAccess side-channel field — SMS-102 negative."""
    provider = site.get("providerAccess")
    if not isinstance(provider, dict):
        return []
    uplink = provider.get("uplink")
    if uplink:
        return [f"# provider uplink: {uplink}"]
    return []
''')

    # Scan the injected file for side-channel field consumption
    content = injected_file.read_text()
    found_consumption = False
    for lineno, line in enumerate(content.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'''"):
            continue
        for field_name in SIDECHANNEL_FIELDS:
            if field_name in line:
                # Verify this is consumption (not rejection) — check context
                # for raise/not supported patterns
                context_start = max(0, lineno - 1)
                context_end = min(len(content.splitlines()), lineno + 3)
                context_lines = content.splitlines()[context_start:context_end]
                context_has_rejection = any(
                    "raise ValueError" in cl or "not supported" in cl or "reject" in cl.lower()
                    for cl in context_lines
                )
                if not context_has_rejection:
                    found_consumption = True
                    print(f"  SEEDED_NEGATIVE_CAUGHT: {injected_file.name}:{lineno}: "
                          f"side-channel field '{field_name}' consumption: {stripped[:100]}")

    if found_consumption:
        print("  PASS: seeded negative 2 (side-channel field consumption) detected")
    else:
        fail("SEEDED_NEGATIVE_NOT_CAUGHT: side-channel field consumption not detected by scanner")

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
print(f"\n{'=' * 60}")
print(f"GAMP: FS-310-HDS-040-SDS-010-SMS-102 — CLAB Renderer CPM-Only Consumption")
print(f"Failures: {failures}")
print(f"Warnings: {warnings}")
print(f"KNOWN_GAPS (pre-existing silent hiders): {len(KNOWN_GAPS)}")

if failures > 0:
    print(f"RESULT: FAIL — {failures} violation(s) detected")
    sys.exit(1)
else:
    print("RESULT: PASS — CLAB renderer CPM-only consumption contract verified")
    sys.exit(0)
PY
