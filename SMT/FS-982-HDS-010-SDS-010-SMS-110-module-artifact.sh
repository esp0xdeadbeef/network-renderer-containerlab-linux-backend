#!/usr/bin/env bash
# GAMP-ID: FS-982-HDS-010-SDS-010-SMS-110
# GAMP-SCOPE: software-module-test
# FS-982-SMS-110-RUNTIME: scoped-artifact
# FS-982-SMS-110-ARTIFACT: CLAB renderer runtime interface mapping artifact
# FS-982-SMS-110-EVIDENCE: tests/FS-320-HDS-010-SDS-010-SMS-030.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL fs982-sms110-clab-smt: $*" >&2
  exit 1
}

evidence="tests/FS-320-HDS-010-SDS-010-SMS-030.sh"
output="$(NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/${evidence}" 2>&1)" || {
  printf '%s\n' "${output}" >&2
  fail "${evidence} failed"
}

grep -Fq "PASS runtime-interface-mapping-refusals" <<<"${output}" \
  || fail "${evidence} did not prove runtime interface mapping refusals"
rg -L -Fq "missing CPM runtimeIfName" \
  "${repo_root}/tests/lib/FS-320-HDS-010-SDS-010-SMS-030" \
  || fail "${evidence} does not assert missing CPM runtimeIfName rejection"

echo "PASS fs982-sms110-clab-smt"
