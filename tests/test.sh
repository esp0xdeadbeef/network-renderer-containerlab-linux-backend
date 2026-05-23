#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  echo "WARN: direct repo tests are partial; set NETWORK_REPO_DIRECT_TEST_OK=1 for intentional focused runs, or run network-codex-agent/scripts/s-router-full-lab-rebuild-loop.sh for the locked full network-* sweep plus live validation." >&2
fi

default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${default_jobs}}"
test_timeout_seconds="${TEST_TIMEOUT_SECONDS:-${NETWORK_REPO_TEST_TIMEOUT_SECONDS:-1800}}"
if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || [[ "${jobs}" -lt 1 ]]; then
  echo "error: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
  exit 2
fi
if ! [[ "${test_timeout_seconds}" =~ ^[0-9]+$ ]] || [[ "${test_timeout_seconds}" -lt 1 ]]; then
  echo "error: TEST_TIMEOUT_SECONDS must be a positive integer, got '${test_timeout_seconds}'" >&2
  exit 2
fi

tests=(
  test-nix-file-loc.sh
  test-regression-md-resolved-states.sh
  test-python-file-loc.sh
  test-s88-python-file-loc.sh
  test-python-format.sh
  test-large-ipv6-prefix-addressing.sh
  test-s88-naming-and-hierarchy.sh
  test-s88-python-readability.sh
  test-rendered-artifact-validator-scratch-dir.sh
  test-provenance-without-git.sh
  test-policy-interface-tags-no-generated-link-parsing.sh
  test-access-tenant-no-node-name-parsing.sh
  test-vm-runtime-log-guard.sh
  test-input-path-override.sh
  test-vm-matrix-resources.sh
  test-vm-matrix-runner.sh
  test-passing-fixtures.sh
  test-dual-wan-branch-overlay.sh
  test-bgp-example.sh
  test-routing-mode-required.sh
  test-policy-firewall.sh
  test-core-nat-wan.sh
  test-tri-site-core-egress-nat.sh
  test-management-eth0-egress-guard.sh
  test-deployment-host-filter.sh
  test-hostile-dns-east-west.sh
  test-dns-service-policy-routes.sh
  test-dns-service-source-binding.sh
  test-hostile-gua-advertisements.sh
  test-host-uplink-vlan-dhcp.sh
  test-nat-uplink-runtime-addressing.sh
  test-linux-route-multipath.sh
  test-overlay-underlay-access-rendering.sh
  test-linux-policy-rule-shell-safety.sh
  test-policy-no-main-defaults.sh
  test-vm-nat-uplink.sh
  test-vm-physical-overlay-post-checks.sh
  test-s-router-clab-overlay-parity.sh
  test-single-overlay-interface-link.sh
  test-vm-example-lab-cleanup.sh
  test-vm-docker-readiness.sh
)

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

declare -A pid_to_name=()
declare -A pid_to_log=()
declare -A pid_to_start=()
running=0
failures=0

wait_for_one() {
  local finished_pid
  local status=0
  wait -n -p finished_pid || status=$?

  local name="${pid_to_name[${finished_pid}]}"
  local log_file="${pid_to_log[${finished_pid}]}"
  local start="${pid_to_start[${finished_pid}]}"
  local elapsed=$((SECONDS - start))
  unset "pid_to_name[${finished_pid}]"
  unset "pid_to_log[${finished_pid}]"
  unset "pid_to_start[${finished_pid}]"
  running=$((running - 1))

  if (( status == 0 )); then
    printf 'PASS %s (%ss)\n' "${name}" "${elapsed}"
  else
    printf 'FAIL %s (exit %s, %ss)\n' "${name}" "${status}" "${elapsed}" >&2
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

printf 'running %s tests with TEST_JOBS=%s\n' "${#tests[@]}" "${jobs}"
for test_name in "${tests[@]}"; do
  test_path="${repo_root}/tests/${test_name}"
  log_file="${tmp_dir}/${test_name}.log"
  printf 'START %s\n' "${test_name}"
  timeout "${test_timeout_seconds}" "${test_path}" >"${log_file}" 2>&1 &
  pid_to_name[$!]="${test_name}"
  pid_to_log[$!]="${log_file}"
  pid_to_start[$!]="${SECONDS}"
  running=$((running + 1))

  if (( running >= jobs )); then
    wait_for_one
  fi
done

while (( running > 0 )); do
  wait_for_one
done

if (( failures > 0 )); then
  printf 'FAIL network-renderer-containerlab-linux-backend: %s test(s) failed\n' "${failures}" >&2
  exit 1
fi

printf 'PASS network-renderer-containerlab-linux-backend: %s tests\n' "${#tests[@]}"
