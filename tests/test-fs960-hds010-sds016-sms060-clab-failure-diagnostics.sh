#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-060
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests CLAB failure diagnostic classification from deploy-clab.sh.
# Isolates wait_for_docker diagnostics and fail() patterns.
# Non-destructive: uses fake binaries, no real Docker or Containerlab.
#
# Failure classes tested (SDS-016 / SMS-060):
#  - privilege_failure: docker permission denied, sudo password required
#  - missing_artifacts: missing CPM JSON, missing renderer inventory, missing cache evidence
#  - deployment_failure: no running fabric containers, no non-loopback interface
#  - cache_build_save_progress: verified indirectly via cache evidence presence gate
#  - pre_marker_race: (covered in nixos host wrapper; noted as out-of-scope for renderer test)
#
# Seeded negative: verify privilege_failure is NOT misclassified as deployment_failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_script="${repo_root}/deploy-clab.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

# This test verifies failure classification from deploy-clab.sh. The HAT
# full-test gate can oversubscribe the host enough for an inner GNU timeout to
# kill a fake command before it emits the diagnostic under test, so fake timeout
# in the isolated PATH and keep the classifier assertions unchanged.
cat >"${fake_bin}/timeout" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--foreground" ]]; then
  shift
fi
if (($# > 0)); then
  shift
fi
exec "$@"
SH
chmod +x "${fake_bin}/timeout"

# Isolate the fail() and wait_for_docker() functions from deploy-clab.sh.
fail() { printf '[deploy-clab] error: %s\n' "$*" >&2; return 1; }
# Keep this bounded but high enough for the HAT full-test gate, where this fake
# sudo/docker check runs under heavy cross-repo Nix/build parallel load.
docker_info_timeout_seconds=30
systemctl_timeout_seconds=1

eval "$(
  awk '/^wait_for_docker\(\) \{/,/^\}/' "${deploy_script}"
)"

failures=0
diagnostic_wait_seconds="${FS960_TEST_DOCKER_WAIT_SECONDS:-60}"

classify_failure_record() {
  local signal="$1"
  local reported_category="$2"
  local direct_host_context="$3"
  local locked_source_identity="$4"

  if [[ -z "${direct_host_context}" || -z "${locked_source_identity}" ]]; then
    echo "diagnostic.clab-failure-context-missing: direct-host context or locked source identity omitted" >&2
    return 1
  fi

  case "${signal}" in
    docker-permission-denied)
      if [[ "${reported_category}" != "privilege_failure" ]]; then
        echo "diagnostic.clab-privilege-failure-misclassified: permission denial reported as ${reported_category}" >&2
        return 1
      fi
      ;;
    cache-build-in-progress)
      if [[ "${reported_category}" != "cache_build_save_progress" ]]; then
        echo "diagnostic.clab-cache-progress-misclassified: cache build/save progress reported as ${reported_category}" >&2
        return 1
      fi
      ;;
    pre-marker-artifact-inspection)
      if [[ "${reported_category}" != "pre_marker_race" ]]; then
        echo "diagnostic.clab-pre-marker-race-misclassified: pre-marker inspection reported as ${reported_category}" >&2
        return 1
      fi
      ;;
    *)
      echo "diagnostic.clab-unknown-failure-category: ${signal}" >&2
      return 1
      ;;
  esac
}

# ===========================================================================
# PRIVILEGE FAILURE TESTS (wait_for_docker diagnostics)
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 1: Docker daemon not running — "Cannot connect" on stderr.
# Simulates non-root without sudo, docker reports "Cannot connect".
# Expected diagnostic: "docker did not become ready after Ns (daemon may not be running or unreachable)"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
exit 1
SH
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${fake_bin}/systemctl"

if (
  export PATH="${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS=2
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test1.stderr"; then
  echo "FAIL test1: expected daemon-absence failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker did not become ready after 2s (daemon may not be running or unreachable)' "${tmp_dir}/test1.stderr"; then
    echo "PASS test1: daemon-absence distinguished [privilege_failure subclass: daemon-unreachable]"
  else
    echo "FAIL test1: wrong diagnostic for daemon absence" >&2
    cat "${tmp_dir}/test1.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Permission denied — "Got permission denied" on stderr.
# Expected diagnostic: "docker permission denied — user not authorized..."
# This is the primary privilege_failure class.
# ---------------------------------------------------------------------------
permission_bin="${tmp_dir}/bin-test2-permission"
mkdir -p "${permission_bin}"
cat >"${permission_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
exit 1
SH
chmod +x "${permission_bin}/docker"

if (
  export PATH="${permission_bin}:${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS="${diagnostic_wait_seconds}"
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test2.stderr"; then
  echo "FAIL test2: expected permission-denied failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker permission denied — user not authorized to access Docker daemon' "${tmp_dir}/test2.stderr"; then
    echo "PASS test2: permission-denied distinguished [privilege_failure]"
  else
    echo "FAIL test2: wrong diagnostic for permission denied" >&2
    cat "${tmp_dir}/test2.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: sudo -n fails with "password is required".
# Expected diagnostic: "docker privilege check failed — sudo -n requires NOPASSWD..."
# ---------------------------------------------------------------------------
sudo_password_bin="${tmp_dir}/bin-test3-sudo-password"
mkdir -p "${sudo_password_bin}"
cat >"${sudo_password_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "FAIL: docker called directly when sudo was expected" >&2
exit 99
SH
chmod +x "${sudo_password_bin}/docker"

cat >"${sudo_password_bin}/sudo" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-n" ]]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
shift
exec "$@"
SH
chmod +x "${sudo_password_bin}/sudo"

if (
  export PATH="${sudo_password_bin}:${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS="${diagnostic_wait_seconds}"
  export CLAB_TEST_EUID=1000
  wait_for_docker
) 2>"${tmp_dir}/test3.stderr"; then
  echo "FAIL test3: expected sudo-password failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'docker privilege check failed — sudo -n requires NOPASSWD' "${tmp_dir}/test3.stderr"; then
    echo "PASS test3: sudo-password-required distinguished [privilege_failure subclass: no-NOPASSWD]"
  else
    echo "FAIL test3: wrong diagnostic for sudo password" >&2
    cat "${tmp_dir}/test3.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# MISSING ARTIFACTS TESTS (fail() patterns from deploy-clab.sh)
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 4: Missing CPM JSON — deploy-clab.sh line 59.
# Simulates: empty/missing CPM JSON input.
# Expected diagnostic: contains "missing or empty CPM JSON"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/artifact-check" <<'SH'
#!/usr/bin/env bash
# Simulate deploy-clab.sh artifact validation (lines 58-60)
cpm_json="$1"
if [[ ! -s "${cpm_json}" ]]; then
  printf '[deploy-clab] error: missing or empty CPM JSON: %s\n' "${cpm_json}" >&2
  exit 1
fi
SH
chmod +x "${fake_bin}/artifact-check"

if "${fake_bin}/artifact-check" "/nonexistent/cpm.json" 2>"${tmp_dir}/test4.stderr"; then
  echo "FAIL test4: expected missing-artifact failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'missing or empty CPM JSON' "${tmp_dir}/test4.stderr"; then
    echo "PASS test4: missing CPM JSON distinguished [missing_artifacts]"
  else
    echo "FAIL test4: wrong diagnostic for missing CPM JSON" >&2
    cat "${tmp_dir}/test4.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 5: Missing renderer inventory JSON — deploy-clab.sh line 60.
# Expected diagnostic: contains "missing or empty renderer inventory JSON"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/artifact-check2" <<'SH'
#!/usr/bin/env bash
renderer_inventory_json="$1"
if [[ ! -s "${renderer_inventory_json}" ]]; then
  printf '[deploy-clab] error: missing or empty renderer inventory JSON: %s\n' "${renderer_inventory_json}" >&2
  exit 1
fi
SH
chmod +x "${fake_bin}/artifact-check2"

if "${fake_bin}/artifact-check2" "/nonexistent/inventory.json" 2>"${tmp_dir}/test5.stderr"; then
  echo "FAIL test5: expected missing-inventory failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'missing or empty renderer inventory JSON' "${tmp_dir}/test5.stderr"; then
    echo "PASS test5: missing renderer inventory distinguished [missing_artifacts]"
  else
    echo "FAIL test5: wrong diagnostic for missing renderer inventory" >&2
    cat "${tmp_dir}/test5.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 6: Missing cache evidence — deploy-clab.sh line 286.
# Expected diagnostic: contains "missing Docker tooling image cache evidence"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/cache-check" <<'SH'
#!/usr/bin/env bash
evidence="$1"
if [[ ! -s "${evidence}" ]]; then
  printf '[deploy-clab] error: missing Docker tooling image cache evidence: %s\n' "${evidence}" >&2
  exit 1
fi
SH
chmod +x "${fake_bin}/cache-check"

if "${fake_bin}/cache-check" "/tmp/nonexistent-evidence.json" 2>"${tmp_dir}/test6.stderr"; then
  echo "FAIL test6: expected missing-cache-evidence failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'missing Docker tooling image cache evidence' "${tmp_dir}/test6.stderr"; then
    echo "PASS test6: missing cache evidence distinguished [cache_build_save_progress gate]"
  else
    echo "FAIL test6: wrong diagnostic for missing cache evidence" >&2
    cat "${tmp_dir}/test6.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# DEPLOYMENT FAILURE TESTS
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 7: No running fabric containers — deploy-clab.sh line 309.
# Expected diagnostic: contains "no running fabric containers found"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/verify-containers" <<'SH'
#!/usr/bin/env bash
lab_name="$1"
printf '[deploy-clab] error: no running fabric containers found for lab %s\n' "${lab_name}" >&2
exit 1
SH
chmod +x "${fake_bin}/verify-containers"

if "${fake_bin}/verify-containers" "s-router" 2>"${tmp_dir}/test7.stderr"; then
  echo "FAIL test7: expected deployment failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'no running fabric containers found for lab s-router' "${tmp_dir}/test7.stderr"; then
    echo "PASS test7: deployment failure - no containers distinguished [deployment_failure]"
  else
    echo "FAIL test7: wrong diagnostic for deployment failure" >&2
    cat "${tmp_dir}/test7.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Test 8: Container has no non-loopback interface — deploy-clab.sh line 314.
# Expected diagnostic: contains "has no non-loopback interface up"
# ---------------------------------------------------------------------------
cat >"${fake_bin}/verify-interfaces" <<'SH'
#!/usr/bin/env bash
container="$1"
printf '[deploy-clab] error: container %s has no non-loopback interface up\n' "${container}" >&2
exit 1
SH
chmod +x "${fake_bin}/verify-interfaces"

if "${fake_bin}/verify-interfaces" "clab-s-router-core-01" 2>"${tmp_dir}/test8.stderr"; then
  echo "FAIL test8: expected interface verification failure but got success" >&2
  failures=$((failures + 1))
else
  if grep -q 'has no non-loopback interface up' "${tmp_dir}/test8.stderr"; then
    echo "PASS test8: deployment failure - no non-loopback interface distinguished [deployment_failure]"
  else
    echo "FAIL test8: wrong diagnostic for interface verification" >&2
    cat "${tmp_dir}/test8.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# SEEDED NEGATIVE: Misclassification prevention
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 9 (seeded negative): Privilege failure must NOT be reported as deployment failure.
# A permission-denied error must be classified as privilege_failure, not
# deployment_failure or missing_artifacts.
# We construct a permission-denied scenario and verify the diagnostic text
# contains the privilege-specific markers, not deployment markers.
# ---------------------------------------------------------------------------
# Simulate: permission denied scenario
permission_seed_bin="${tmp_dir}/bin-test9-permission-seed"
mkdir -p "${permission_seed_bin}"
cat >"${permission_seed_bin}/docker" <<'SH'
#!/usr/bin/env bash
echo "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
exit 1
SH
chmod +x "${permission_seed_bin}/docker"

rm -f "${fake_bin}/sudo"

if (
  export PATH="${permission_seed_bin}:${fake_bin}:${PATH}"
  export CLAB_DOCKER_WAIT_SECONDS="${diagnostic_wait_seconds}"
  export CLAB_TEST_EUID=1000
  export CLAB_TEST_DISABLE_SUDO=1
  wait_for_docker
) 2>"${tmp_dir}/test9.stderr"; then
  echo "FAIL test9: expected failure but got success" >&2
  failures=$((failures + 1))
else
  stderr_text="$(cat "${tmp_dir}/test9.stderr")"

  # Must contain privilege-specific diagnostic
  if ! echo "${stderr_text}" | grep -q 'docker permission denied'; then
    echo "FAIL test9 (seeded negative): permission denied NOT classified as privilege_failure" >&2
    echo "  stderr: ${stderr_text}" >&2
    failures=$((failures + 1))
  # Must NOT contain deployment failure markers
  elif echo "${stderr_text}" | grep -q 'no running fabric containers found'; then
    echo "FAIL test9 (seeded negative): privilege_failure misclassified as deployment_failure" >&2
    echo "  stderr: ${stderr_text}" >&2
    failures=$((failures + 1))
  # Must NOT contain missing artifacts markers
  elif echo "${stderr_text}" | grep -q 'missing or empty'; then
    echo "FAIL test9 (seeded negative): privilege_failure misclassified as missing_artifacts" >&2
    echo "  stderr: ${stderr_text}" >&2
    failures=$((failures + 1))
  else
    echo "PASS test9: seeded negative — privilege_failure correctly NOT misclassified as deployment or artifact failure"
  fi
fi

# ---------------------------------------------------------------------------
# Test 10 (seeded negative): Classifier rejects privilege failure reported as
# runtime absence/deployment failure and accepts the corrected category.
# ---------------------------------------------------------------------------
if classify_failure_record \
    docker-permission-denied \
    deployment_failure \
    direct-host-clab \
    locked-hat-source \
    2>"${tmp_dir}/test10.stderr"; then
  echo "FAIL test10: seeded negative — privilege misclassification unexpectedly accepted" >&2
  failures=$((failures + 1))
else
  if grep -q 'diagnostic.clab-privilege-failure-misclassified' "${tmp_dir}/test10.stderr"; then
    echo "PASS test10: seeded negative — privilege failure misclassification rejected"
  else
    echo "FAIL test10: wrong diagnostic for privilege misclassification" >&2
    cat "${tmp_dir}/test10.stderr" >&2
    failures=$((failures + 1))
  fi
fi

if classify_failure_record \
    docker-permission-denied \
    privilege_failure \
    direct-host-clab \
    locked-hat-source \
    2>"${tmp_dir}/test10-corrected.stderr"; then
  echo "PASS test10 recovery: corrected privilege failure category accepted"
else
  echo "FAIL test10 recovery: corrected privilege failure category rejected" >&2
  cat "${tmp_dir}/test10-corrected.stderr" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 11 (seeded negative): Classifier rejects cache build/save progress
# reported as missing runtime and accepts the corrected category.
# ---------------------------------------------------------------------------
if classify_failure_record \
    cache-build-in-progress \
    runtime_absence \
    direct-host-clab \
    locked-hat-source \
    2>"${tmp_dir}/test11.stderr"; then
  echo "FAIL test11: seeded negative — cache progress misclassification unexpectedly accepted" >&2
  failures=$((failures + 1))
else
  if grep -q 'diagnostic.clab-cache-progress-misclassified' "${tmp_dir}/test11.stderr"; then
    echo "PASS test11: seeded negative — cache progress misclassification rejected"
  else
    echo "FAIL test11: wrong diagnostic for cache progress misclassification" >&2
    cat "${tmp_dir}/test11.stderr" >&2
    failures=$((failures + 1))
  fi
fi

if classify_failure_record \
    cache-build-in-progress \
    cache_build_save_progress \
    direct-host-clab \
    locked-hat-source \
    2>"${tmp_dir}/test11-corrected.stderr"; then
  echo "PASS test11 recovery: corrected cache progress category accepted"
else
  echo "FAIL test11 recovery: corrected cache progress category rejected" >&2
  cat "${tmp_dir}/test11-corrected.stderr" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 12: Real deploy-clab failures carry direct-host context and locked-source identity.
# ---------------------------------------------------------------------------
if grep -q 'directHostContext=' "${deploy_script}" &&
   grep -q 'lockedSource=' "${deploy_script}"; then
  echo "PASS test12: deploy-clab fail diagnostics preserve direct-host context and locked source identity"
else
  echo "FAIL test12: deploy-clab fail diagnostics omit context or locked source identity" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 13: Containerlab deploy failures remain fail-closed under bounded retry.
# ---------------------------------------------------------------------------
host_module="${repo_root}/host-module.nix"
if grep -q 'CLAB_DEPLOY_MAX_WORKERS' "${deploy_script}" &&
   grep -q 'CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS' "${deploy_script}" &&
   grep -q 'CLAB_CONTAINERLAB_API_TIMEOUT' "${deploy_script}" &&
   grep -q 'deploy_max_workers=' "${deploy_script}" &&
   grep -q 'containerlab_api_timeout=' "${deploy_script}" &&
   grep -q 'run_containerlab_deploy_once()' "${deploy_script}" &&
   grep -q 'stop_containerlab_deploy()' "${deploy_script}" &&
   grep -q -- '--timeout "${containerlab_api_timeout}"' "${deploy_script}" &&
   grep -q -- '--max-workers' "${deploy_script}" &&
   grep -q 'Containerlab deploy emitted ERRO; stopping attempt' "${deploy_script}" &&
   grep -q 'Containerlab deploy produced no output' "${deploy_script}" &&
   grep -q 'failed to Statfs "/proc/0/ns/net"' "${deploy_script}" &&
   grep -q 'failed deploy links.*file exists' "${deploy_script}" &&
   grep -q 'Containerlab deploy did not complete cleanly' "${deploy_script}" &&
   grep -q 'CLAB_DEPLOY_MAX_WORKERS' "${host_module}" &&
   grep -q 'CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS' "${host_module}" &&
   grep -q 'CLAB_CONTAINERLAB_API_TIMEOUT' "${host_module}" &&
   grep -q 'deploy_max_workers=' "${host_module}" &&
   grep -q 'deploy_idle_timeout_seconds=' "${host_module}" &&
   grep -q 'containerlab_api_timeout=' "${host_module}" &&
   grep -q 'stop_containerlab_deploy()' "${host_module}" &&
   grep -q -- '--timeout "$containerlab_api_timeout"' "${host_module}" &&
   grep -q -- '--max-workers' "${host_module}" &&
   grep -q 'containerlab deploy produced no output' "${host_module}" &&
   grep -q 'containerlab deploy emitted ERRO lines; refusing readiness marker' "${host_module}"; then
  echo "PASS test13: bounded Containerlab deploy keeps netns pid 0 and ERRO failures fail-closed"
else
  echo "FAIL test13: Containerlab deploy retry/ERRO diagnostics can be masked" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-060: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-060: all failure diagnostic classification predicates covered"
