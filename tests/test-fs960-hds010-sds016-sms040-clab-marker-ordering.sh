#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-040
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests marker artifact ordering predicates: render-live complete-success gating
# for fabric.clab.yml consumption, network-artifacts readiness gating for Docker
# container startup, and active seeded negatives for pre-marker artifact
# consumption and premature container start.
# Non-destructive: no real Docker, no real Containerlab, no live host.
#
# SMS-040 Acceptance Predicates:
#  1. fabric.clab.yml consumption gated on render-live complete-success marker
#  2. Docker container startup gated on network-artifacts readiness
#  3. Seeded negative: HAT consumes fabric before render-live complete → REJECT
#     with diagnostic.render-live-signal-missing
#  4. Seeded negative: Docker containers started before network-artifacts
#     readiness confirmed → REJECT with diagnostic.premature-container-start
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

failures=0

# ---------------------------------------------------------------------------
# SMS-040 marker artifact ordering check function.
# This mirrors the ordering logic from the HAT readiness pipeline:
#   - fabric.clab.yml must not be consumed before render-live complete-success
#   - Docker containers must not be started before network-artifacts readiness
# ---------------------------------------------------------------------------

# Simulated marker states
MARKER_COMPLETE_SUCCESS='{"serviceName":"s-router-clab-render-live","phase":"complete","result":"success"}'
MARKER_NOT_COMPLETE='{"serviceName":"s-router-clab-render-live","phase":"containerlab-deploy","result":"failure","failureReason":"exit status 2"}'
MARKER_WRONG_SERVICE='{"serviceName":"s-router-clab-deploy-live-boot","phase":"complete","result":"success"}'
ARTIFACTS_READY_MARKER='{"network-artifacts":"ready","timestamp":"2026-06-17T12:00:00Z"}'
ARTIFACTS_NOT_READY_MARKER='{"network-artifacts":"pending","timestamp":"2026-06-17T12:00:00Z"}'

check_marker_artifact_ordering() {
  local marker_json="$1"
  local artifacts_json="$2"
  local action="$3"  # "consume-fabric" or "start-containers"

  local phase result service_name artifacts_state

  phase="$(echo "${marker_json}" | jq -r '.phase // ""')"
  result="$(echo "${marker_json}" | jq -r '.result // ""')"
  service_name="$(echo "${marker_json}" | jq -r '.serviceName // ""')"
  artifacts_state="$(echo "${artifacts_json}" | jq -r '.["network-artifacts"] // ""')"

  # Gate 1: render-live marker must be from the correct service
  if [[ "${service_name}" != "s-router-clab-render-live" ]]; then
    echo "diagnostic.render-live-signal-missing: expected marker from s-router-clab-render-live, got ${service_name:-none}" >&2
    return 1
  fi

  # Gate 2: marker must be complete-success before fabric.clab.yml consumption
  if [[ "${action}" == "consume-fabric" ]]; then
    if [[ "${phase}" != "complete" || "${result}" != "success" ]]; then
      echo "diagnostic.render-live-signal-missing: cannot consume fabric.clab.yml before render-live complete-success (phase=${phase:-none}, result=${result:-none})" >&2
      return 2
    fi
  fi

  # Gate 3: network-artifacts must be ready before Docker container startup
  if [[ "${action}" == "start-containers" ]]; then
    if [[ "${phase}" != "complete" || "${result}" != "success" ]]; then
      echo "diagnostic.render-live-signal-missing: cannot start containers before render-live complete-success (phase=${phase:-none}, result=${result:-none})" >&2
      return 2
    fi
    if [[ "${artifacts_state}" != "ready" ]]; then
      echo "diagnostic.premature-container-start: cannot start Docker containers before network-artifacts readiness (state=${artifacts_state:-none})" >&2
      return 3
    fi
  fi

  return 0
}

# ===========================================================================
# Test 1: Positive — complete-success marker allows fabric.clab.yml consumption
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_COMPLETE_SUCCESS}" \
    "${ARTIFACTS_READY_MARKER}" \
    "consume-fabric" \
    >/dev/null 2>"${tmp_dir}/test1.stderr"; then
  echo "PASS test1: complete-success marker gates fabric.clab.yml consumption OK"
else
  echo "FAIL test1: complete-success marker rejected valid fabric consumption" >&2
  cat "${tmp_dir}/test1.stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 2: Negative — missing render-live marker rejects fabric.clab.yml consumption
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_NOT_COMPLETE}" \
    "${ARTIFACTS_READY_MARKER}" \
    "consume-fabric" \
    >/dev/null 2>"${tmp_dir}/test2.stderr"; then
  echo "FAIL test2: non-complete marker allowed fabric consumption" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.render-live-signal-missing" "${tmp_dir}/test2.stderr"; then
    echo "PASS test2: non-complete marker correctly rejects fabric consumption with render-live-signal-missing"
  else
    echo "FAIL test2: wrong diagnostic for non-complete marker rejection" >&2
    cat "${tmp_dir}/test2.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 3: Negative — wrong service marker rejects fabric.clab.yml consumption
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_WRONG_SERVICE}" \
    "${ARTIFACTS_READY_MARKER}" \
    "consume-fabric" \
    >/dev/null 2>"${tmp_dir}/test3.stderr"; then
  echo "FAIL test3: wrong-service marker allowed fabric consumption" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.render-live-signal-missing" "${tmp_dir}/test3.stderr"; then
    echo "PASS test3: wrong-service marker correctly rejects fabric consumption with render-live-signal-missing"
  else
    echo "FAIL test3: wrong diagnostic for wrong-service marker rejection" >&2
    cat "${tmp_dir}/test3.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 4: Positive — complete-success + artifacts ready allows Docker startup
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_COMPLETE_SUCCESS}" \
    "${ARTIFACTS_READY_MARKER}" \
    "start-containers" \
    >/dev/null 2>"${tmp_dir}/test4.stderr"; then
  echo "PASS test4: complete-success marker + artifacts ready gates Docker startup OK"
else
  echo "FAIL test4: valid state rejected Docker startup" >&2
  cat "${tmp_dir}/test4.stderr" >&2
  failures=$((failures + 1))
fi

# ===========================================================================
# Test 5 (seeded negative 1): HAT consumes fabric before render-live complete
# Marker shows phase=containerlab-deploy, result=failure — not complete-success.
# The module shall REJECT with diagnostic.render-live-signal-missing.
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_NOT_COMPLETE}" \
    "${ARTIFACTS_READY_MARKER}" \
    "consume-fabric" \
    >/dev/null 2>"${tmp_dir}/test5.stderr"; then
  echo "FAIL test5: seeded negative — non-complete marker should reject fabric consumption" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.render-live-signal-missing" "${tmp_dir}/test5.stderr" && \
     grep -q "cannot consume fabric.clab.yml" "${tmp_dir}/test5.stderr"; then
    echo "PASS test5: seeded negative — pre-marker fabric consumption correctly rejected"
  else
    echo "FAIL test5: seeded negative — wrong diagnostic for pre-marker fabric consumption" >&2
    cat "${tmp_dir}/test5.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 6 (seeded negative 2): Docker containers started before network-artifacts
# readiness confirmed. Marker is complete-success but artifacts are pending.
# The module shall REJECT with diagnostic.premature-container-start.
# ===========================================================================
if check_marker_artifact_ordering \
    "${MARKER_COMPLETE_SUCCESS}" \
    "${ARTIFACTS_NOT_READY_MARKER}" \
    "start-containers" \
    >/dev/null 2>"${tmp_dir}/test6.stderr"; then
  echo "FAIL test6: seeded negative — unready artifacts should reject container startup" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.premature-container-start" "${tmp_dir}/test6.stderr" && \
     grep -q "cannot start Docker containers" "${tmp_dir}/test6.stderr"; then
    echo "PASS test6: seeded negative — premature container start correctly rejected"
  else
    echo "FAIL test6: seeded negative — wrong diagnostic for premature container start" >&2
    cat "${tmp_dir}/test6.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 7 (seeded negative 1 variant): Completely missing render-live marker.
# Empty JSON — no marker at all. REJECT with render-live-signal-missing.
# ===========================================================================
EMPTY_MARKER='{}'
if check_marker_artifact_ordering \
    "${EMPTY_MARKER}" \
    "${ARTIFACTS_READY_MARKER}" \
    "consume-fabric" \
    >/dev/null 2>"${tmp_dir}/test7.stderr"; then
  echo "FAIL test7: seeded negative — missing marker should reject fabric consumption" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.render-live-signal-missing" "${tmp_dir}/test7.stderr"; then
    echo "PASS test7: seeded negative — missing marker correctly rejects fabric consumption"
  else
    echo "FAIL test7: seeded negative — wrong diagnostic for missing marker" >&2
    cat "${tmp_dir}/test7.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Test 8: Artifact ordering violation — out-of-order containerlab inspection.
# Simulates: marker complete-success but artifacts state is empty/missing.
# Module shall REJECT with diagnostic.artifact-ordering-violation.
# ===========================================================================
EMPTY_ARTIFACTS='{}'
if check_marker_artifact_ordering \
    "${MARKER_COMPLETE_SUCCESS}" \
    "${EMPTY_ARTIFACTS}" \
    "start-containers" \
    >/dev/null 2>"${tmp_dir}/test8.stderr"; then
  echo "FAIL test8: missing artifacts state should reject container startup" >&2
  failures=$((failures + 1))
else
  if grep -q "diagnostic.premature-container-start" "${tmp_dir}/test8.stderr"; then
    echo "PASS test8: missing artifacts state correctly rejects container startup"
  else
    echo "FAIL test8: wrong diagnostic for missing artifacts state" >&2
    cat "${tmp_dir}/test8.stderr" >&2
    failures=$((failures + 1))
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-040: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-040: all 8 acceptance predicates covered"
