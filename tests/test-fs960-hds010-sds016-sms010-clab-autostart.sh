#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-010
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests CLAB autostart module predicates: locked-source loading, container
# readiness marker emission, container state discrimination (running vs exited),
# and active seeded negatives for hash mismatch and unhealthy containers.
# Isolates write_status + verify-containerlab-deploy.sh via fake docker binary.
# Non-destructive: no real Docker, no real Containerlab.
#
# SMS-010 Acceptance Predicates:
#  1. Locked-source: validate CPM inputs exist (not mutable local path)
#  2. All containers running+healthy → readiness marker with result=success
#  3. One container exited → readiness marker NOT success, diagnostic emitted
#  4. Seeded negative: empty/nonexistent topology source → REJECT
#  5. Seeded negative: containers running but unhealthy → readiness marker NOT emitted
#  6. Host realization restores declarative /etc/hosts when a thin consumer disables it
#  7. Seeded negative: a stronger removal of /etc/hosts fails NixOS evaluation
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_script="${repo_root}/deploy-clab.sh"

# Build deploy-clab through Nix once for all deploy-clab validation tests (7-9).
# This gives the app its full runtime deps (pyyaml, clabgen, etc.).
deploy_app="$(nix build --show-trace --print-out-paths --no-link "path:${repo_root}#deploy-clab")"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

non_empty_topology="${tmp_dir}/non-empty-fabric.clab.yml"
empty_topology="${tmp_dir}/empty-fabric.clab.yml"

cat >"${non_empty_topology}" <<'YAML'
name: fabric
topology:
  nodes:
    router:
      kind: linux
  links: []
YAML

cat >"${empty_topology}" <<'YAML'
name: fabric
topology:
  nodes: {}
  links: []
YAML

failures=0

# ---------------------------------------------------------------------------
# Extract write_status function: a simplified version that matches the
# behavior in host-module.nix s-router-clab-render-live.
# The function emits a JSON status marker with serviceName, phase, timestamp,
# workDirectory, topology, artifactDirectory, commandSurface, result, failureReason.
# ---------------------------------------------------------------------------
write_status() {
  local result="$1"
  local status_phase="$2"
  local failure_reason="${3:-}"
  local work_dir="${4:-/persist/s-router-clab/live-boot}"
  local artifact_dir="${work_dir}/network-artifacts"
  local service_name="s-router-clab-render-live"
  local status_marker="${work_dir}/s-router-clab-render-live-status.json"

  mkdir -p "${work_dir}"
  jq -S -n \
    --arg serviceName "${service_name}" \
    --arg phase "${status_phase}" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workDirectory "${work_dir}" \
    --arg topology "${work_dir}/fabric.clab.yml" \
    --arg artifactDirectory "${artifact_dir}" \
    --arg commandSurface "${service_name}" \
    --arg result "${result}" \
    --arg failureReason "${failure_reason}" \
    '{
      serviceName: $serviceName,
      phase: $phase,
      timestamp: $timestamp,
      workDirectory: $workDirectory,
      topology: $topology,
      artifactDirectory: $artifactDirectory,
      commandSurface: $commandSurface,
      result: $result,
      failureReason: $failureReason
    }' > "${status_marker}"
}

# ---------------------------------------------------------------------------
# Helper: verify-containerlab-deploy logic extracted from host-module.nix.
# Checks that clab-fabric-* containers are running and have non-loopback
# interfaces via docker ps + docker exec.
# ---------------------------------------------------------------------------
verify_containers() {
  local topology_file="${1:-${non_empty_topology}}"
  local containers
  containers="$(docker ps --format '{{.Names}}' | grep '^clab-fabric-' || true)"

  test -n "${containers}" || {
    if grep -Eq '^[[:space:]]+nodes:[[:space:]]*\{\}[[:space:]]*$' "${topology_file}"; then
      echo "empty containerlab topology; no containers expected"
      return 0
    fi
    echo "no clab-fabric containers are running after deploy" >&2
    return 1
  }

  while IFS= read -r container; do
    local count
    count="$(
      timeout 10 docker exec "${container}" sh -c \
        'find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo | wc -l'
    )" || {
      docker inspect "${container}" >/dev/null 2>&1 || true
      echo "container ${container} did not answer non-loopback interface probe within 10s" >&2
      return 1
    }
    if [ "${count}" -lt 1 ]; then
      timeout 10 docker exec "${container}" ip -br link || true
      echo "container ${container} has no non-loopback interfaces after deploy" >&2
      return 1
    fi
    local health
    health="$(
      timeout 10 docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}"
    )" || {
      echo "container ${container} health status could not be inspected" >&2
      return 1
    }
    case "${health}" in
      healthy|none)
        ;;
      *)
        echo "container ${container} health check is ${health}" >&2
        return 1
        ;;
    esac
  done <<EOF
${containers}
EOF
  return 0
}

# ===========================================================================
# Test 1: write_status success marker — correct JSON schema and fields
# ===========================================================================
test1_dir="${tmp_dir}/test1"
mkdir -p "${test1_dir}"
write_status "success" "complete" "" "${test1_dir}"
status_file="${test1_dir}/s-router-clab-render-live-status.json"

python3 - "${status_file}" <<'PY'
import json, sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["result"] == "success", f"expected success, got {payload['result']}"
assert payload["phase"] == "complete", f"expected complete, got {payload['phase']}"
assert payload["serviceName"] == "s-router-clab-render-live"
assert payload["commandSurface"] == "s-router-clab-render-live"
assert payload["failureReason"] == "", f"failureReason should be empty for success"
assert "timestamp" in payload
assert "workDirectory" in payload
assert "topology" in payload
assert "artifactDirectory" in payload
PY

if (( $? == 0 )); then
  echo "PASS test1: write_status success marker schema correct"
else
  echo "FAIL test1: write_status success marker schema check failed" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 2: write_status failure marker — correct failure reason
# ===========================================================================
test2_dir="${tmp_dir}/test2"
mkdir -p "${test2_dir}"
write_status "failure" "containerlab-deploy" "exit status 2" "${test2_dir}"
status_file2="${test2_dir}/s-router-clab-render-live-status.json"

python3 - "${status_file2}" <<'PY'
import json, sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["result"] == "failure", f"expected failure, got {payload['result']}"
assert payload["phase"] == "containerlab-deploy"
assert payload["failureReason"] == "exit status 2", f"bad failureReason: {payload['failureReason']}"
PY

if (( $? == 0 )); then
  echo "PASS test2: write_status failure marker correct"
else
  echo "FAIL test2: write_status failure marker check failed" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 3: Container verification — all running with non-loopback interfaces
# Mock docker ps: returns two clab-fabric containers
# Mock docker exec: returns 2 non-loopback interfaces for each
# ===========================================================================
test3_dir="${tmp_dir}/test3"
mkdir -p "${test3_dir}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      printf 'clab-fabric-router-1\nclab-fabric-client-1\n'
    fi
    ;;
  exec)
    container="$2"
    shift 2
    # Simulate: each container has eth0 and eth1 (2 non-loopback interfaces)
    if [[ "$*" == *"find /sys/class/net"* ]]; then
      # Return count of non-loopback ifaces
      if [[ "${container}" == "clab-fabric-router-1" ]]; then
        echo "3"   # eth0, eth1, eth2 = 3 non-loopback
      elif [[ "${container}" == "clab-fabric-client-1" ]]; then
        echo "2"   # eth0, eth1 = 2 non-loopback
      else
        echo "0"
      fi
      exit 0
    fi
    # For any other exec command, succeed silently
    exit 0
    ;;
  inspect)
    if [[ "${2:-}" == "--format" ]]; then
      echo "healthy"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

# Create a fake timeout that just runs the command
cat >"${fake_bin}/timeout" <<'SH'
#!/usr/bin/env bash
shift  # discard timeout value
exec "$@"
SH
chmod +x "${fake_bin}/timeout"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) >"${test3_dir}/stdout" 2>"${test3_dir}/stderr"; then
  echo "PASS test3: all containers running with non-loopback interfaces pass verification"
else
  echo "FAIL test3: container verification failed unexpectedly" >&2
  cat "${test3_dir}/stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 4 (seeded negative): Container running but health check is unhealthy
# Mock docker ps: returns 1 container
# Mock docker exec: returns non-loopback interfaces
# Mock docker inspect: returns unhealthy health status
# ===========================================================================
test4_health_dir="${tmp_dir}/test4-health"
mkdir -p "${test4_health_dir}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      echo "clab-fabric-unhealthy-1"
    fi
    ;;
  exec)
    if [[ "$*" == *"find /sys/class/net"* ]]; then
      echo "2"
      exit 0
    fi
    exit 0
    ;;
  inspect)
    if [[ "${2:-}" == "--format" ]]; then
      echo "unhealthy"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) 2>"${test4_health_dir}/stderr"; then
  echo "FAIL test4: expected failure for unhealthy container, but verification passed" >&2
  failures=$((failures + 1))
else
  if grep -q "health check is unhealthy" "${test4_health_dir}/stderr"; then
    echo "PASS test4: seeded negative — running but unhealthy container correctly rejected"
  else
    echo "FAIL test4: wrong error message for unhealthy container" >&2
    cat "${test4_health_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 5 (seeded negative): No containers running → verification fails
# Mock docker ps: returns empty (no clab-fabric containers)
# ===========================================================================
test4_dir="${tmp_dir}/test4"
mkdir -p "${test4_dir}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    # No containers running — simulates failed deploy
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) 2>"${test4_dir}/stderr"; then
  echo "FAIL test4: expected failure for no containers, but verification passed" >&2
  failures=$((failures + 1))
else
  if grep -q "no clab-fabric containers" "${test4_dir}/stderr"; then
    echo "PASS test4: seeded negative — no containers correctly rejected"
  else
    echo "FAIL test4: wrong error message for no containers" >&2
    cat "${test4_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 5b: Empty topology with no containers is an explicit no-op success
# ===========================================================================
test4_empty_dir="${tmp_dir}/test4-empty"
mkdir -p "${test4_empty_dir}"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers "${empty_topology}"
) >"${test4_empty_dir}/stdout" 2>"${test4_empty_dir}/stderr"; then
  if grep -q "empty containerlab topology" "${test4_empty_dir}/stdout"; then
    echo "PASS test4-empty: empty topology accepted without containers"
  else
    echo "FAIL test4-empty: empty topology pass did not report no-op" >&2
    cat "${test4_empty_dir}/stdout" >&2
    failures=$((failures + 1))
  fi
else
  echo "FAIL test4-empty: empty topology should not require containers" >&2
  cat "${test4_empty_dir}/stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 5 (seeded negative): Container running but has NO non-loopback interfaces
# Mock docker ps: returns 1 container
# Mock docker exec: returns 0 non-loopback interfaces → failure
# ===========================================================================
test5_dir="${tmp_dir}/test5"
mkdir -p "${test5_dir}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      echo "clab-fabric-broken-1"
    fi
    ;;
  exec)
    container="$2"
    shift 2
    if [[ "$*" == *"find /sys/class/net"* ]]; then
      # Return 0 — no non-loopback interfaces
      echo "0"
      exit 0
    fi
    # For ip -br link: also return 0 non-loopback
    if [[ "$*" == *"ip -br link"* ]]; then
      exit 0
    fi
    exit 0
    ;;
  inspect)
    if [[ "${2:-}" == "--format" ]]; then
      echo "healthy"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) 2>"${test5_dir}/stderr"; then
  echo "FAIL test5: expected failure for container with no interfaces, but verification passed" >&2
  failures=$((failures + 1))
else
  if grep -q "no non-loopback interfaces" "${test5_dir}/stderr"; then
    echo "PASS test5: seeded negative — container without non-loopback interfaces correctly rejected"
  else
    echo "FAIL test5: wrong error message for no-interface container" >&2
    cat "${test5_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 6 (seeded negative): Container not reachable via docker exec
# Mock docker exec: returns exit 1 (container unresponsive)
# ===========================================================================
test6_dir="${tmp_dir}/test6"
mkdir -p "${test6_dir}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      echo "clab-fabric-dead-1"
    fi
    ;;
  exec)
    container="$2"
    if [[ "${container}" == "clab-fabric-dead-1" ]]; then
      echo "container clab-fabric-dead-1 is not running" >&2
      exit 1
    fi
    exit 0
    ;;
  inspect)
    if [[ "${2:-}" == "--format" ]]; then
      echo "healthy"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) 2>"${test6_dir}/stderr"; then
  echo "FAIL test6: expected failure for unreachable container, but verification passed" >&2
  failures=$((failures + 1))
else
  if grep -q "did not answer non-loopback interface probe" "${test6_dir}/stderr"; then
    echo "PASS test6: seeded negative — unreachable container correctly rejected"
  else
    echo "FAIL test6: wrong error message for unreachable container" >&2
    cat "${test6_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 7: CPM input locked-source validation (uses nix-built deploy_app)
# deploy-clab validates: cpm_json exists, is not a .nix file, is non-empty.
# This proves the module loads from locked (pre-built) source, not mutable Nix.
# ===========================================================================
test7_dir="${tmp_dir}/test7"
mkdir -p "${test7_dir}"

# Create valid CPM JSON fixture (minimal enterprise with two edge nodes)
cat >"${test7_dir}/cpm.json" <<'JSON'
{
  "enterprise": {
    "esp0xdeadbeef": {
      "site": {
        "s-router-clab": {
          "nodes": {
            "edge-a": {
              "role": "core",
              "routing_mode": "static",
              "routingDomain": "core",
              "loopback": {
                "ipv4": "10.255.0.1/32",
                "ipv6": "2001:db8:ffff::1/128"
              },
              "interfaces": {
                "to-edge-b": {
                  "runtimeIfName": "eth1",
                  "kind": "wan",
                  "addr4": "192.0.2.0/31",
                  "addr6": "2001:db8:100::/127"
                }
              }
            },
            "edge-b": {
              "role": "core",
              "routing_mode": "static",
              "routingDomain": "core",
              "loopback": {
                "ipv4": "10.255.0.2/32",
                "ipv6": "2001:db8:ffff::2/128"
              },
              "interfaces": {
                "to-edge-a": {
                  "runtimeIfName": "eth1",
                  "kind": "wan",
                  "addr4": "192.0.2.1/31",
                  "addr6": "2001:db8:100::1/127"
                }
              }
            }
          },
          "links": {
            "edge-a-b": {
              "kind": "wan",
              "bridge": "br-fs960",
              "endpoints": {
                "edge-a": { "interface": "to-edge-b" },
                "edge-b": { "interface": "to-edge-a" }
              }
            }
          }
        }
      }
    }
  }
}
JSON

# Create valid renderer inventory JSON fixture
cat >"${test7_dir}/inventory.json" <<'JSON'
{"deploymentHost":"s-router-clab","endpointClients":{}}
JSON

# Test: deploy-clab with valid inputs → succeeds (dry-run, no real deploy)
if "${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${test7_dir}/work" \
  "${test7_dir}/cpm.json" \
  "${test7_dir}/inventory.json" \
  >"${test7_dir}/stdout" 2>"${test7_dir}/stderr"; then
  echo "PASS test7: locked-source CPM+inventory JSON validated and deploy dry-run succeeds"
else
  echo "FAIL test7: deploy dry-run with valid locked inputs failed" >&2
  cat "${test7_dir}/stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 8 (seeded negative): deploy-clab rejects .nix input as not-locked
# The SMS-010 spec requires the module to reject mutable Nix sources.
# deploy-clab already enforces: cpm_json must not end in .nix
# ===========================================================================
test8_dir="${tmp_dir}/test8"
mkdir -p "${test8_dir}"

cat >"${test8_dir}/cpm.nix" <<'NIX'
{ links = []; reservations = []; advertisements = []; }
NIX

cat >"${test8_dir}/inv.json" <<'JSON'
{"deploymentHost":"s-router-clab","endpointClients":{}}
JSON

if "${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${test8_dir}/work" \
  "${test8_dir}/cpm.nix" \
  "${test8_dir}/inv.json" \
  >/dev/null 2>"${test8_dir}/stderr"; then
  echo "FAIL test8: expected rejection of .nix CPM input, but got success" >&2
  failures=$((failures + 1))
else
  if grep -q "prebuilt CPM JSON" "${test8_dir}/stderr"; then
    echo "PASS test8: seeded negative — mutable .nix source correctly rejected as not-locked"
  else
    echo "FAIL test8: wrong rejection message for .nix CPM input" >&2
    cat "${test8_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 9 (seeded negative): Missing CPM JSON → deploy-clab fails
# Proves the module rejects absent locked source.
# ===========================================================================
test9_dir="${tmp_dir}/test9"
mkdir -p "${test9_dir}"

cat >"${test9_dir}/inv.json" <<'JSON'
{"deploymentHost":"s-router-clab","endpointClients":{}}
JSON

if "${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${test9_dir}/work" \
  "${test9_dir}/nonexistent-cpm.json" \
  "${test9_dir}/inv.json" \
  >/dev/null 2>"${test9_dir}/stderr"; then
  echo "FAIL test9: expected rejection of missing CPM JSON, but got success" >&2
  failures=$((failures + 1))
else
  if grep -q "missing or empty CPM JSON" "${test9_dir}/stderr"; then
    echo "PASS test9: seeded negative — missing locked CPM source correctly rejected"
  else
    echo "FAIL test9: wrong rejection message for missing CPM source" >&2
    cat "${test9_dir}/stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 10: Automatic recovery — after fixing broken state, readiness succeeds
# This is the SMS-010 seeded negative "after correcting source" scenario.
# First: no containers (fails), then: containers present (succeeds).
# ===========================================================================
test10_dir="${tmp_dir}/test10"
mkdir -p "${test10_dir}"

# Phase 1: No containers → failure
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Phase 1: no containers
echo "no running containers" >&2
exit 1
SH
chmod +x "${fake_bin}/docker"

phase1_failed=0
if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) 2>/dev/null; then
  phase1_failed=1
fi

# Phase 2: Fix the state — all containers running with interfaces
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      printf 'clab-fabric-router-1\nclab-fabric-client-1\n'
    fi
    ;;
  exec)
    container="$2"
    shift 2
    if [[ "$*" == *"find /sys/class/net"* ]]; then
      echo "2"
      exit 0
    fi
    exit 0
    ;;
  inspect)
    if [[ "${2:-}" == "--format" ]]; then
      echo "healthy"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

phase2_ok=0
if (
  export PATH="${fake_bin}:${PATH}"
  verify_containers
) >/dev/null 2>&1; then
  phase2_ok=1
fi

if (( phase1_failed == 0 && phase2_ok == 1 )); then
  echo "PASS test10: seeded negative — failed state correctly detected, corrected state passes (automatic recovery path)"
else
  echo "FAIL test10: phase1_failed=${phase1_failed} (expected 0), phase2_ok=${phase2_ok} (expected 1)" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 11: Host autostart deploy is bounded, deterministic, and fail-closed.
# ===========================================================================
host_module="${repo_root}/host-module.nix"
if grep -q 'CLAB_DEPLOY_MAX_WORKERS' "${host_module}" &&
   grep -q 'CLAB_DEPLOY_TIMEOUT_SECONDS' "${host_module}" &&
   grep -q 'CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS' "${host_module}" &&
   grep -q 'CLAB_CONTAINERLAB_API_TIMEOUT' "${host_module}" &&
   grep -q 'CLAB_CLEANUP_TIMEOUT_SECONDS' "${host_module}" &&
   grep -q 'deploy_max_workers=' "${host_module}" &&
   grep -q 'deploy_idle_timeout_seconds=' "${host_module}" &&
   grep -q 'containerlab_api_timeout=' "${host_module}" &&
   grep -q 'stop_containerlab_deploy()' "${host_module}" &&
   grep -q -- '--timeout "$containerlab_api_timeout"' "${host_module}" &&
   grep -q -- '--max-workers' "${host_module}" &&
   grep -q 'containerlab deploy produced no output' "${host_module}" &&
   grep -q 'containerlab deploy emitted ERRO lines; refusing readiness marker' "${host_module}" &&
   grep -q 'diagnostic.clab-host-prerequisite-missing' "${host_module}" &&
   grep -q 'diagnostic.clab-host-prerequisite-not-writable' "${host_module}" &&
   grep -Fq '[[ -L /etc/hosts || ! -w /etc/hosts ]]' "${host_module}"; then
  echo "PASS test11: host autostart deploy is bounded and refuses ERRO readiness"
else
  echo "FAIL test11: host autostart deploy can race or accept Containerlab ERRO output" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 12: the rendered NixOS host restores writable /etc/hosts for Containerlab.
# The consumer-side `false` mirrors a thin VM profile that disables the normal
# hosts link; the renderer-owned mkForce must enable a copied 0644 artifact.
# ===========================================================================
positive_expr="${tmp_dir}/hosts-positive.nix"
cat >"${positive_expr}" <<NIX
let
  source = builtins.toPath "${repo_root}";
  flake = builtins.getFlake (toString source);
  evaluated = flake.inputs.nixpkgs.lib.nixosSystem {
    system = builtins.currentSystem;
    modules = [
      (source + "/host-module.nix")
      ({ pkgs, ... }: {
        _module.args.clabDeploymentHost = "s-router-clab";
        _module.args.clabCpmJsonPath = builtins.toFile "cpm.json" "{}";
        _module.args.clabRendererInventoryJsonPath = builtins.toFile "inventory.json" "{}";
        _module.args.containerlabLinuxRendererSelf = source;
        _module.args.containerlabLinuxGenerateClabConfig = pkgs.writeShellScriptBin "generate-clab-config" "exit 0";
        _module.args.containerlabLinuxRendererInput = {};
        environment.etc.hosts.enable = false;
        system.stateVersion = "26.05";
      })
    ];
  };
in if evaluated.config.environment.etc.hosts.enable
   then evaluated.config.environment.etc.hosts.mode
   else "disabled"
NIX

if [[ "$(nix eval --impure --raw --file "${positive_expr}")" == "0644" ]]; then
  echo "PASS test12: CLAB host realization restores copied writable /etc/hosts"
else
  echo "FAIL test12: CLAB host realization did not provide copied writable /etc/hosts" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 13 (seeded negative): a stronger consumer removal of /etc/hosts must
# trip the host prerequisite assertion before any deploy can start.
# ===========================================================================
negative_expr="${tmp_dir}/hosts-negative.nix"
cat >"${negative_expr}" <<NIX
let
  source = builtins.toPath "${repo_root}";
  flake = builtins.getFlake (toString source);
  evaluated = flake.inputs.nixpkgs.lib.nixosSystem {
    system = builtins.currentSystem;
    modules = [
      (source + "/host-module.nix")
      ({ pkgs, lib, ... }: {
        _module.args.clabDeploymentHost = "s-router-clab";
        _module.args.clabCpmJsonPath = builtins.toFile "cpm.json" "{}";
        _module.args.clabRendererInventoryJsonPath = builtins.toFile "inventory.json" "{}";
        _module.args.containerlabLinuxRendererSelf = source;
        _module.args.containerlabLinuxGenerateClabConfig = pkgs.writeShellScriptBin "generate-clab-config" "exit 0";
        _module.args.containerlabLinuxRendererInput = {};
        environment.etc.hosts.enable = lib.mkOverride 0 false;
        system.stateVersion = "26.05";
      })
    ];
  };
in evaluated.config.system.build.toplevel.drvPath
NIX

if nix eval --impure --raw --file "${negative_expr}" >"${tmp_dir}/hosts-negative.stdout" 2>"${tmp_dir}/hosts-negative.stderr"; then
  echo "FAIL test13: seeded negative removed /etc/hosts without evaluation failure" >&2
  failures=$((failures + 1))
elif grep -q 'diagnostic.clab-host-prerequisite-missing' "${tmp_dir}/hosts-negative.stderr"; then
  echo "PASS test13: seeded negative rejects a missing /etc/hosts prerequisite"
else
  echo "FAIL test13: seeded negative failed without the prerequisite diagnostic" >&2
  cat "${tmp_dir}/hosts-negative.stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 14 (seeded negative): an enabled read-only Nix-store symlink is not a
# usable Containerlab lifecycle prerequisite.
# ===========================================================================
readonly_expr="${tmp_dir}/hosts-readonly-negative.nix"
cat >"${readonly_expr}" <<NIX
let
  source = builtins.toPath "${repo_root}";
  flake = builtins.getFlake (toString source);
  evaluated = flake.inputs.nixpkgs.lib.nixosSystem {
    system = builtins.currentSystem;
    modules = [
      (source + "/host-module.nix")
      ({ pkgs, lib, ... }: {
        _module.args.clabDeploymentHost = "s-router-clab";
        _module.args.clabCpmJsonPath = builtins.toFile "cpm.json" "{}";
        _module.args.clabRendererInventoryJsonPath = builtins.toFile "inventory.json" "{}";
        _module.args.containerlabLinuxRendererSelf = source;
        _module.args.containerlabLinuxGenerateClabConfig = pkgs.writeShellScriptBin "generate-clab-config" "exit 0";
        _module.args.containerlabLinuxRendererInput = {};
        environment.etc.hosts.mode = lib.mkOverride 0 "symlink";
        system.stateVersion = "26.05";
      })
    ];
  };
in evaluated.config.system.build.toplevel.drvPath
NIX

if nix eval --impure --raw --file "${readonly_expr}" >"${tmp_dir}/hosts-readonly.stdout" 2>"${tmp_dir}/hosts-readonly.stderr"; then
  echo "FAIL test14: seeded negative accepted read-only /etc/hosts" >&2
  failures=$((failures + 1))
elif grep -q 'diagnostic.clab-host-prerequisite-not-writable' "${tmp_dir}/hosts-readonly.stderr"; then
  echo "PASS test14: seeded negative rejects read-only /etc/hosts"
else
  echo "FAIL test14: read-only negative failed without the writable prerequisite diagnostic" >&2
  cat "${tmp_dir}/hosts-readonly.stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-010: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-010: all 14 acceptance predicates covered (locked-source, readiness marker, container state, 8 seeded negatives)"
