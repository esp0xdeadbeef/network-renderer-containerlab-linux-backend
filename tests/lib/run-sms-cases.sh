#!/usr/bin/env bash
set -euo pipefail

helper_path="$(readlink -f "${BASH_SOURCE[0]}")"
tests_root="$(cd "$(dirname "${helper_path}")/.." && pwd)"
repo_root="$(cd "${tests_root}/.." && pwd)"
trace_id="${1:-$(basename "$0" .sh)}"
[[ "${trace_id}" == FS-*-HDS-*-SDS-*-SMS-* ]] || {
  printf 'usage: %s <trace-id>\n' "$0" >&2
  exit 2
}

mapfile -t cases < <(find "${tests_root}/lib/${trace_id}" -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)
((${#cases[@]} > 0)) || {
  printf 'FAIL %s: no internal test cases found\n' "${trace_id}" >&2
  exit 1
}
executed=0
skipped=0
for test_case in "${cases[@]}"; do
  if grep -Fqx '# GAMP-EXECUTION: live' "${test_case}" \
    && [[ "${NETWORK_REPO_RUNTIME_TEST_OK:-0}" != "1" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  SMS_TEST_REPO_ROOT="${repo_root}" SMS_TEST_TRACE_ID="${trace_id}" bash "${test_case}"
  executed=$((executed + 1))
done
printf 'PASS %s: %s case(s) executed, %s live case(s) skipped\n' \
  "${trace_id}" "${executed}" "${skipped}"
