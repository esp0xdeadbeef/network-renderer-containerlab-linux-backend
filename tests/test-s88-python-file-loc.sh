#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
limit="${S88_PY_LOC_LIMIT:-200}"

mapfile -t oversized < <(
  cd "$repo_root"
  find clabgen/s88 -type f -name '*.py' -print0 \
    | xargs -0 -r wc -l \
    | awk -v limit="$limit" '
      $2 != "total" && $1 > limit {
        print $1 " " $2
      }' \
    | sort -nr
)

if ((${#oversized[@]} > 0)); then
  printf 'S88 Python files over %s lines:\n' "$limit" >&2
  printf '%s\n' "${oversized[@]}" >&2
  exit 1
fi
