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
  test-regression-md-resolved-states.sh
  test-fs100-renderer-output-provenance.sh
  test-fs310-hds010-sds010-sms040-interface-name-source-binding.sh
  test-fs310-hds010-sds010-sms050-nftables-primitive-source-binding.sh
  test-fs310-hds010-sds010-sms060-route-command-source-binding.sh
  test-fs310-hds010-sds010-sms070-nat-primitive-source-binding.sh
  test-fs310-hds010-sds010-sms080-shell-fallback-error-propagation.sh
  test-fs310-hds010-sds010-sms090-check-bypass-prevention.sh
  test-fs310-hds010-sds010-sms190-pppoe-no-default.sh
  test-fs310-hds010-sds010-sms200-bridge-no-default.sh
  test-fs310-hds010-sds010-sms210-route-table-allocation.sh
  test-fs380-hds010-sds010-sms060-core-wan-ip-assignment.sh
  test-runtime-interface-mapping-refusals.sh
  test-bridge-link-realization-contracts.sh
  test-lab-emulation-capability-gate.sh
  test-provider-access-pppoe-artifacts.sh
  test-deploy-clab-app-contract.sh
  test-clab-tooling-cache-evidence.sh
  test-topology-conformance-parity-guard.sh
  test-bgp-cpm-contract-render.sh
  test-fs760-policy-firewall-forwarding-intent.sh
  test-role-independent-cm-inputs.sh
  test-access-advertisements-runtime.sh
  test-dns-namespace-fallback-cpm-contract.sh
  test-fs540-hds010-sds010-sms035-dns-self-referential-guard.sh
  test-policy-no-main-defaults.sh
  test-fs960-hds010-sds016-sms050-clab-privileged-inspect.sh
)

if [[ "${NETWORK_REPO_RUNTIME_TEST_OK:-0}" == "1" ]]; then
  tests+=(
    test-provider-access-pppoe-runtime.sh
  )
fi

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
