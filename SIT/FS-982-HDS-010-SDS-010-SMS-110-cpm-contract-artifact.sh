#!/usr/bin/env bash
# GAMP-ID: FS-982-HDS-010-SDS-010-SMS-110
# GAMP-SCOPE: software-integration-test
# FS-982-SMS-110-RUNTIME: scoped-artifact
# FS-982-SMS-110-ARTIFACT: CLAB renderer CPM topology conformance artifact
# FS-982-SMS-110-EVIDENCE: tests/FS-320-HDS-010-SDS-010-SMS-010.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL fs982-sms110-clab-sit: $*" >&2
  exit 1
}

evidence="tests/FS-320-HDS-010-SDS-010-SMS-010.sh"
output="$(NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/${evidence}" 2>&1)" || {
  printf '%s\n' "${output}" >&2
  fail "${evidence} failed"
}

grep -Fq "PASS topology-conformance-parity-guard" <<<"${output}" \
  || fail "${evidence} did not prove topology conformance parity"
rg -L -Fq "validate-topology-conformance.sh" \
  "${repo_root}/tests/lib/FS-320-HDS-010-SDS-010-SMS-010" \
  || fail "${evidence} does not validate rendered CLAB topology against CPM JSON"

echo "PASS fs982-sms110-clab-sit"
