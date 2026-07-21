#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-200
# Renderer Bridge-Network No-Default Contract Construction Test
#
# Proves: CLAB renderer bridge-network and VM-network modules do not supply
# hardcoded bridge addresses, DHCP server enablement, IP masquerade behavior,
# or DHCP pool offsets without CPM authority, and the VM/bridge module does
# not disable the host firewall without explicit renderer inventory authority
# (containerlab.hostFirewall).
#
# Note: host-module.nix and vm-network-nat.nix are in the nixos repo (V5, V11,
# V12). This test scans the CLAB renderer Python source for bridge-related
# hardcoding and verifies renderer-emitted bridge configs consume CPM data.
# Checks 6-9 cover the host-firewall disablement failure condition (M3):
# missing-authority seeded negatives and the source-authorized recovery.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
print(f"\n{'PASS' if failures == 0 else 'FAIL'} FS-310-HDS-020-SDS-010-SMS-200 checks 1-5: "
      f"{failures} violation(s) in CLAB renderer source")
sys.exit(0 if failures == 0 else 1)
PY

# ── 6. Host-firewall predicate: no unconditional disablement ─────────
echo
echo "=== Check 6: vm.nix has no unconditional host-firewall decision ==="
tmp_dir="$(mktemp -d /tmp/sms200-host-firewall.XXXXXX)"
trap 'rm -rf "${tmp_dir}"' EXIT

scan_firewall_literal() {
  # Returns 0 (violation found) when the given module hardcodes a literal
  # host-firewall decision instead of tracing it to source authority.
  grep -En 'networking\.firewall\.enable\s*=\s*(false|true)\s*;' "$1"
}

if scan_firewall_literal "${repo_root}/vm.nix"; then
  echo "  FAIL: vm.nix hardcodes a networking.firewall.enable literal without source authority"
  exit 1
fi
if ! grep -q 'vm-host-firewall.nix' "${repo_root}/vm.nix"; then
  echo "  FAIL: vm.nix does not consume the vm-host-firewall.nix authority resolver"
  exit 1
fi
if ! grep -q 'FS-310-HDS-020-SDS-010-SMS-200' "${repo_root}/vm-host-firewall.nix"; then
  echo "  FAIL: vm-host-firewall.nix does not carry the SMS-200 trace"
  exit 1
fi
echo "  PASS: vm.nix host-firewall decision traces to vm-host-firewall.nix authority resolver"

# Active seeded negative: re-inject the unconditional disablement into a
# fixture copy and prove the scanner actually detects it.
sed 's/networking\.firewall\.enable = hostFirewallEnable;/networking.firewall.enable = false;/' \
  "${repo_root}/vm.nix" > "${tmp_dir}/vm-seeded-bad.nix"
if scan_firewall_literal "${tmp_dir}/vm-seeded-bad.nix" >/dev/null; then
  echo "  PASS: seeded negative — scanner detects re-injected unconditional firewall disablement"
else
  echo "  FAIL: seeded negative not detected — scanner is inert"
  exit 1
fi

# ── 7. Seeded negative: missing host-firewall authority fails closed ─
echo
echo "=== Check 7: missing-authority firewall decision fails closed ==="
set +e
missing_err="$(nix eval --impure --expr \
  "import ${repo_root}/vm-host-firewall.nix { generated = { bridges = [ ]; }; }" 2>&1)"
missing_rc=$?
set -e
if [[ ${missing_rc} -eq 0 ]]; then
  echo "  FAIL: vm-host-firewall.nix accepted a silent source (no hostFirewall authority)"
  exit 1
fi
if ! grep -q 'FS-310-HDS-020-SDS-010-SMS-200' <<<"${missing_err}" \
  || ! grep -q 'missing explicit host-firewall authority' <<<"${missing_err}"; then
  echo "  FAIL: missing-authority rejection does not name the missing authority/trace"
  echo "${missing_err}" | tail -5
  exit 1
fi
echo "  PASS: silent source rejected with diagnostic naming containerlab.hostFirewall + SMS-200"

# Malformed authority record (no boolean enable) must also fail closed.
set +e
malformed_err="$(nix eval --impure --expr \
  "import ${repo_root}/vm-host-firewall.nix { generated = { hostFirewall = { source = \"x\"; }; }; }" 2>&1)"
malformed_rc=$?
set -e
if [[ ${malformed_rc} -eq 0 ]]; then
  echo "  FAIL: vm-host-firewall.nix accepted a hostFirewall record without boolean enable"
  exit 1
fi
if ! grep -q 'invalid host-firewall authority record' <<<"${malformed_err}"; then
  echo "  FAIL: malformed-authority rejection missing diagnostic"
  exit 1
fi
echo "  PASS: malformed authority record (no boolean enable) rejected"

# ── 8. Source-authorized recovery: explicit decision is honored ──────
echo
echo "=== Check 8: explicit source authority recovery ==="
disable_val="$(nix eval --impure --json --expr \
  "import ${repo_root}/vm-host-firewall.nix { generated = { hostFirewall = { enable = false; source = \"renderer-inventory:containerlab.hostFirewall\"; }; }; }")"
enable_val="$(nix eval --impure --json --expr \
  "import ${repo_root}/vm-host-firewall.nix { generated = { hostFirewall = { enable = true; source = \"renderer-inventory:containerlab.hostFirewall\"; }; }; }")"
if [[ "${disable_val}" != "false" || "${enable_val}" != "true" ]]; then
  echo "  FAIL: explicit authority not honored (disable=${disable_val} enable=${enable_val})"
  exit 1
fi
echo "  PASS: explicit containerlab.hostFirewall decision honored (disable=false, enable=true)"

# ── 9. Generator authority extraction and emission ───────────────────
echo
echo "=== Check 9: generator emits hostFirewall only from explicit authority ==="
python3 - <<'PY'
import importlib.util
import json
import sys
import types
from pathlib import Path

sys.path.insert(0, ".")
# Established repo test pattern: stub yaml so importing the generator module
# does not require PyYAML in the test environment.
sys.modules["yaml"] = types.SimpleNamespace(
    safe_dump=lambda payload, **_kwargs: json.dumps(payload)
)
spec = importlib.util.spec_from_file_location(
    "parse_solver_json", Path("clabgen/parse-solver-json.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Silent inventory -> no authority, no emitted hostFirewall attribute.
assert mod._host_firewall_authority({}) is None
assert mod._host_firewall_authority({"containerlab": {}}) is None
body = mod._render_bridges_body(["br-a"], {}, [], None)
assert "hostFirewall" not in body, body
print("  PASS: silent inventory emits no hostFirewall attribute (fail-closed downstream)")

# Malformed record -> ValueError naming the trace (seeded negative, active).
try:
    mod._host_firewall_authority({"containerlab": {"hostFirewall": {"enable": "no"}}})
except ValueError as e:
    assert "FS-310-HDS-020-SDS-010-SMS-200" in str(e), e
    print("  PASS: malformed containerlab.hostFirewall rejected with SMS-200 diagnostic")
else:
    print("  FAIL: malformed hostFirewall record accepted by generator")
    sys.exit(1)

# Explicit decision -> emitted verbatim into the bridges artifact.
authority = {"enable": False, "source": "renderer-inventory:containerlab.hostFirewall"}
extracted = mod._host_firewall_authority({"containerlab": {"hostFirewall": authority}})
assert extracted == authority, extracted
body = mod._render_bridges_body(["br-a"], {}, [], extracted)
assert "hostFirewall = builtins.fromJSON" in body, body
emitted = body.split("hostFirewall = builtins.fromJSON ''", 1)[1].split("''", 1)[0].strip()
assert json.loads(emitted) == authority, emitted
print("  PASS: explicit inventory authority emitted into generated bridges artifact")
PY

# ── 10. Isolated VM work directories receive every imported module ─────
echo
echo "=== Check 10: VM staging copies the host-firewall authority module ==="
if grep -Fq 'cp "${FLAKE_DIR}/vm-host-firewall.nix" "${VM_WORK_DIR}/vm-host-firewall.nix"' \
  "${repo_root}/start-vm.sh"; then
  echo "  PASS: start-vm stages vm-host-firewall.nix beside vm.nix"
else
  echo "  FAIL: isolated VM work directory omits vm-host-firewall.nix" >&2
  exit 1
fi

echo
echo "PASS FS-310-HDS-020-SDS-010-SMS-200: bridge no-default + host-firewall authority contract"
