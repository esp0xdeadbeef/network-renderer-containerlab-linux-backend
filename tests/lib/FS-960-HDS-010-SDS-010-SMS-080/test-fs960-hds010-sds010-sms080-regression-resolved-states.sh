#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-010-SMS-080
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
regression="${repo_root}/regression.md"

if [[ ! -f "${regression}" ]]; then
  echo "FAIL regression.md state gate: missing ${regression}" >&2
  exit 1
fi

allowed_re='^solved$'
violations=()

while IFS=: read -r line text; do
  state="$(sed -n 's/.*state=\([^ |`]*\).*/\1/p' <<<"${text}")"
  [[ -n "${state}" ]] || continue

  if [[ ! "${state}" =~ ${allowed_re} ]]; then
    violations+=("${regression}:${line}: state=${state}: ${text}")
  fi
done < <(grep -n 'state=' "${regression}" || true)

if ((${#violations[@]} > 0)); then
  echo "FAIL regression.md state gate: unresolved regression states remain." >&2
  echo "Fix the owning bug, then update the entry to state=solved after evidence." >&2
  printf '%s\n' "${violations[@]}" >&2
  exit 1
fi

echo "PASS regression-md-resolved-states"
