#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-102
# Construction test: CLAB Renderer CPM-Only Consumption
# Proves: CLAB renderer consumes ONLY CPM-mediated output (no direct
# intent/inventory imports, no silent error hiders, no side-channel
# field consumption, entrypoints require CPM JSON, flake.nix hostModule
# accepts cpm struct not raw paths).
#
# FS-310-HDS-040-SDS-010-SMS-102 is the CLAB per-renderer child spec of FS-310-HDS-040-SDS-010-SMS-100.
# Two active seeded negative cases required per SMS §Seeded Negative Requirement.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
        fail(f"KNOWN_GAP file removed (remove from list): {gap_path}")
        continue
    lines = gap_file.read_text().splitlines()
    if gap_lineno > len(lines):
        fail(f"KNOWN_GAP line {gap_lineno} out of range in {gap_path} (remove from list)")
        continue
    line = lines[gap_lineno - 1]
    if not EXCEPT_PATTERN.match(line):
        fail(f"KNOWN_GAP line {gap_lineno} in {gap_path} no longer matches — gap may be fixed (remove from list)")

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
# CHECK 5: flake.nix hostModule consumes the released canonical bundle
# FS-310-HDS-040-SDS-010-SMS-100: the host wiring takes one validated bundle
# and has no raw-CPM entry point left.
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 5: flake.nix hostModule consumes the released canonical bundle ===")

flake_nix = repo / "flake.nix"
flake_content = flake_nix.read_text()

has_host_module = "hostModule = canonicalHostModule" in flake_content
has_bundle_input = "bundle," in flake_content and "rendererInputJsonPath" in flake_content
accepts_raw_cpm = "rendererInput ? cpm" in flake_content or "rendererInput.cpm" in flake_content

if not has_host_module:
    fail("flake.nix renderer.hostModule is not the canonical bundle host module")
if not has_bundle_input:
    fail("flake.nix hostModule does not take a bundle and hand the host a renderer input path")
if accepts_raw_cpm:
    fail("flake.nix hostModule still accepts a raw cpm payload")

if has_host_module and has_bundle_input and not accepts_raw_cpm:
    print("  PASS: flake.nix hostModule consumes the released bundle and rejects raw cpm")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 5b: both producer envelope shapes reach the same solver input
# The SMT fixtures carry the semantic model, the real pipeline carries a
# control-plane envelope; wrapping either one twice drops `.data`.
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 5b: the solver maps canonical collections and refuses the raw artifact ===")

from clabgen.canonical_bundle import control_plane_envelope  # noqa: E402
from clabgen.cpm_solver import control_plane_model_to_solver_json  # noqa: E402

site_b = {
    "runtimeTargets": {"router-a": {}},
    "forwardingSemantics": {"nodes": {}},
    "transit": {},
}
canonical = {
    "canonicalSites": {"byEnterprise": {"esp": {"site-b": site_b}}},
    "canonicalInterfaces": [],
    "canonicalRoutes": [],
    "canonicalRuntimeTargets": {"targets": []},
    "canonicalForwarding": {},
}


def released(payload):
    """The renderer-input view: canonical collections + stamps, NO 'network' key.

    This is what network-realization-model.lib.validateRendererInput(...)
    .rendererInput serialises. The old shape here was a released bundle carrying
    `network.data`, which the row now refuses -- the check that accepted it was
    asserting the bypass.
    """
    return {
        "kind": "network-realization-bundle",
        "bundleIdentity": "bundle-x",
        "validation": {"valid": True, "artifactIdentity": "bundle-x"},
        **payload,
    }


check5b_fails = 0

solver = control_plane_model_to_solver_json(control_plane_envelope(released({"canonical": canonical})))
targets = (
    solver.get("enterprise", {})
    .get("esp", {})
    .get("site", {})
    .get("site-b", {})
    .get("runtimeTargets")
)
if targets != {"router-a": {}}:
    fail(f"canonical bundle did not reach the solver: {solver!r}")
    check5b_fails += 1

# The raw producer artifact must be refused, not rendered.
try:
    control_plane_envelope(released({"network": {"data": {"data": {}}}}))
except Exception as exc:  # noqa: BLE001 - the gate must fail closed
    if "GAMP-MODEL-BOUNDARY-VIOLATION" not in str(exc):
        fail(f"bundle carrying 'network' raised the wrong diagnostic: {exc}")
        check5b_fails += 1
else:
    fail("bundle carrying 'network' was accepted as renderer input")
    check5b_fails += 1

# A bundle with neither is not renderable either.
try:
    control_plane_envelope(released({"version": 1}))
except Exception as exc:  # noqa: BLE001 - the gate must fail closed
    if "GAMP-MODEL-BOUNDARY-VIOLATION" not in str(exc):
        fail(f"bundle without canonical collections raised the wrong diagnostic: {exc}")
        check5b_fails += 1
else:
    fail("bundle without canonical collections was accepted")
    check5b_fails += 1

if check5b_fails == 0:
    print("  PASS: canonical collections reach the solver; 'network' and empty inputs fail closed")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 5c: the renderer's input gate runs on realization-model + schema
# FS-310-HDS-040-SDS-010-SMS-100 and the network-realization-schema README
# put every renderer downstream of the realization model and its published
# contract. Prove the containerlab path carries both repos and that the
# schema-bound release stamp is enforced at the renderer boundary.
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 5c: containerlab gate uses realization-model + schema ===")

check5c_fails = 0
if "network-realization-model.lib.validateRendererInput" not in flake_content:
    fail("flake.nix canonical gate does not run network-realization-model.lib.validateRendererInput")
    check5c_fails += 1

import json  # noqa: E402
import subprocess  # noqa: E402

lock = json.loads((repo / "flake.lock").read_text())
if "network-realization-model" not in lock["nodes"]["root"]["inputs"]:
    fail("flake.lock has no network-realization-model input")
    check5c_fails += 1
realization_node = lock["nodes"].get("network-realization-model", {})
if "network-realization-schema" not in realization_node.get("inputs", {}):
    fail("the containerlab path does not carry network-realization-schema through the realization model")
    check5c_fails += 1

fixture = r'''
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    realization = flake.inputs.network-realization-model;
    schema = realization.inputs.network-realization-schema;
    cpm = {
      kind = "network-control-plane-artifact";
      artifactIdentity = "sms102-schema-gate";
      artifactDigest = builtins.hashString "sha256" "sms102-schema-gate";
      control_plane_model = {
        data.example.site.runtimeTargets.core-1 = {
          role = "core";
          interfaces = { };
          forwarding = { };
        };
        meta.source = "sms102-schema-gate";
      };
    };
    bundle = realization.lib.realize {
      input = cpm;
      requestScope = { kind = "complete-artifact"; identity = "sms102-schema-gate"; };
      rootLockIdentity = "sms102-schema-gate";
      producerRevision = realization.rev or "local";
    };
    validate = value: flake.libBySystem.${system}.renderer.canonical.validateInput { bundle = value; };
    mutated = bundle // {
      network = bundle.network // {
        data = bundle.network.data // { meta = (bundle.network.data.meta or {}) // { source = "mutated"; }; };
      };
    };
    wrongSchema = bundle // {
      validation = bundle.validation // { schemaSetIdentity = builtins.hashString "sha256" "other-schema"; };
    };
    noValidation = builtins.removeAttrs bundle [ "validation" ];
  in
'''

# The released schema set is the one the containerlab input graph carries.
identity_expr = fixture + "{ released = bundle.validation.schemaSetIdentity; pinned = schema.lib.schemaSetIdentity; }"
proc = subprocess.run(
    ["nix", "eval", "--impure", "--json", "--expr", identity_expr],
    cwd=str(repo),
    capture_output=True,
    text=True,
    env={**os.environ, "REPO_ROOT": str(repo.resolve())},
)
if proc.returncode != 0:
    fail(f"could not read the release/containerlab schema identities: {(proc.stderr or '').strip()[-400:]}")
    check5c_fails += 1
else:
    identities = json.loads(proc.stdout)
    if identities["released"] != identities["pinned"]:
        fail("the bundle was released under a different schema set than the containerlab input graph carries")
        check5c_fails += 1

cases = {
    "released bundle": (fixture + "validate bundle", True, None),
    "mutated network data": (fixture + "validate mutated", False, "NR_ARTIFACT_DIGEST_MISMATCH"),
    "missing release stamp": (fixture + "validate noValidation", False, "NR_RENDERER_BUNDLE_UNVALIDATED"),
    "wrong schema set": (fixture + "validate wrongSchema", False, "NR_RENDERER_BUNDLE_UNVALIDATED"),
}

for label, (expr, expect_ok, diagnostic) in cases.items():
    proc = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        cwd=str(repo),
        capture_output=True,
        text=True,
        env={**os.environ, "REPO_ROOT": str(repo.resolve())},
    )
    output = (proc.stderr or "") + (proc.stdout or "")
    if expect_ok:
        if proc.returncode != 0:
            fail(f"released bundle was rejected by the renderer gate: {output.strip()[-400:]}")
            check5c_fails += 1
    elif proc.returncode == 0:
        fail(f"{label} was accepted by the renderer gate")
        check5c_fails += 1
    elif diagnostic not in output:
        fail(f"{label} failed with the wrong diagnostic (expected {diagnostic}): {output.strip()[-400:]}")
        check5c_fails += 1

if check5c_fails == 0:
    print("  PASS: gate runs on realization-model + schema, stamps agree, mutation and forged stamps fail closed")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 5d: target mechanics come from the model, not from the renderer
# FS-410/FS-540: the control plane publishes `clampMssInterfaces` for
# interfaces whose modeled MTU cannot carry full-size segments. The renderer
# clamps the NAT-authorized WAN and exactly that published set; it must not
# invent clamps for interfaces the model did not name, and must not drop a
# clamp the model did name.
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 5d: MSS clamp set comes from clampMssInterfaces ===")

from clabgen.s88.CM.firewall_wan import render as render_wan_firewall  # noqa: E402
from clabgen.s88.EM.base import _wan_firewall_cm_input  # noqa: E402

check5d_fails = 0
node = {
    "interfaces": {
        "wan": {"runtimeIfName": "wan", "sourceKind": "wan"},
        "tunnel": {"runtimeIfName": "gre0", "sourceKind": "p2p", "mtu": 1400},
    },
    "natIntent": {"wanInterfaces": ["wan"]},
    "clampMssInterfaces": ["gre0"],
}
cm_input = _wan_firewall_cm_input(node, {"wan": "wan", "tunnel": "gre0"})
if cm_input.get("clamp_interfaces") != ["gre0"]:
    fail(f"clampMssInterfaces did not reach the CM input: {cm_input.get('clamp_interfaces')!r}")
    check5d_fails += 1
commands = render_wan_firewall(cm_input)
clamped = {
    command.split('oifname "')[1].split('"')[0]
    for command in commands
    if "maxseg size set rt mtu" in command
}
if clamped != {"wan", "gre0"}:
    fail(f"clamped interfaces are {sorted(clamped)}, expected the WAN and the published low-MTU set")
    check5d_fails += 1

node_without_clamp = {k: v for k, v in node.items() if k != "clampMssInterfaces"}
cm_without_clamp = _wan_firewall_cm_input(node_without_clamp, {"wan": "wan", "tunnel": "gre0"})
commands_without_clamp = render_wan_firewall(cm_without_clamp)
clamped_without = {
    command.split('oifname "')[1].split('"')[0]
    for command in commands_without_clamp
    if "maxseg size set rt mtu" in command
}
if clamped_without != {"wan"}:
    fail(f"renderer invented clamps without the model field: {sorted(clamped_without)}")
    check5d_fails += 1

if check5d_fails == 0:
    print("  PASS: WAN clamp from NAT intent, extra clamps only from the published set")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 6: Entrypoints consume the canonical realization bundle
# FS-310-HDS-040-SDS-010-SMS-100: CPM output is upstream authority for
# network-realization-model; renderers receive one validated canonical
# realization bundle and reject raw CPM payloads.
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 6: entrypoints consume the canonical realization bundle ===")

gate = repo / "clabgen" / "canonical_bundle.py"
if not gate.exists():
    fail("  clabgen/canonical_bundle.py missing: renderer has no canonical-input gate")
gate_content = gate.read_text()
for needle in ("network-realization-bundle", "GAMP-MODEL-BOUNDARY-VIOLATION", "control_plane_envelope"):
    if needle not in gate_content:
        fail(f"  clabgen/canonical_bundle.py missing boundary marker {needle!r}")
print("  PASS: canonical-input gate rejects raw CPM and requires a released bundle")

solver_content = (repo / "clabgen" / "solver.py").read_text()
if "control_plane_envelope" not in solver_content or "bundle" not in solver_content:
    fail("  clabgen/solver.py does not route bundle input through the canonical gate")
print("  PASS: solver loads renderer meaning from the canonical bundle envelope")

gen_py = repo / "generate-clab-config.py"
gen_content = gen_py.read_text()
if "canonical realization bundle" not in gen_content:
    fail("  generate-clab-config.py does not require a canonical realization bundle")
if "CPM JSON" in gen_content:
    fail("  generate-clab-config.py still advertises a raw CPM JSON input")
print("  PASS: generate-clab-config.py requires the canonical bundle input")

runner_content = (repo / "run-clab-generator.sh").read_text()
if "GAMP-MODEL-BOUNDARY-VIOLATION" not in runner_content:
    fail("  run-clab-generator.sh does not reject a raw control-plane-model payload")
print("  PASS: run-clab-generator.sh rejects raw control-plane-model payloads")

# The renderer inventory must not be read out of a raw CPM payload.
parser_content = (repo / "clabgen" / "parse-solver-json.py").read_text()
if 'cpm.get("endpointInventory")' in parser_content:
    fail("  clabgen/parse-solver-json.py still reads endpointInventory from a raw CPM payload")
print("  PASS: renderer inventory is not sourced from a raw CPM payload")

# deploy-clab.sh
deploy_sh = repo / "deploy-clab.sh"
deploy_content = deploy_sh.read_text()
rejects_nix = "*.nix" in deploy_content and "fail" in deploy_content and "CPM JSON" in deploy_content
if rejects_nix or "intent/inventory Nix" in deploy_content:
    print("  PASS: deploy-clab.sh requires CPM JSON, rejects .nix input")
else:
    warn("  deploy-clab.sh: verify CPM JSON requirement (may use other validation)")

# ═══════════════════════════════════════════════════════════════════════
# CHECK 7: Normal rendering does not emit ad-hoc diagnostic chatter
# ═══════════════════════════════════════════════════════════════════════
print("\n=== Check 7: no unconditional normal-render DIAGNOSTIC chatter ===")

normal_diag_patterns = [
    "DIAGNOSTIC: node=",
    "has core-uplink-egress?",
    "interface runtimeNames:",
]
diag_fails = 0
for py_file in sorted(repo.glob("clabgen/**/*.py")):
    content = py_file.read_text()
    for pattern in normal_diag_patterns:
        if pattern in content:
            rel_path = str(py_file.relative_to(repo))
            fail(f"{rel_path}: unconditional render diagnostic pattern {pattern!r}")
            diag_fails += 1

if diag_fails == 0:
    print("  PASS: renderer normal path has no unconditional DIAGNOSTIC stderr")

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
    """Inject CPM data with silent error swallowing — FS-310-HDS-040-SDS-010-SMS-102 negative."""
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
    """Consume upstreamEmulation side-channel field — FS-310-HDS-040-SDS-010-SMS-102 negative."""
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
    """Consume providerAccess side-channel field — FS-310-HDS-040-SDS-010-SMS-102 negative."""
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
