#!/usr/bin/env bash
set -euo pipefail

guard_vm_runtime_log() {
  local log_file="$1"

  if [[ ! -s "${log_file}" ]]; then
    echo "VM runtime log is missing or empty: ${log_file}" >&2
    return 1
  fi

  if grep -Eq '(^|[[:space:]])ERRO([[:space:]]|$)|containers not found|cannot exec in a stopped state|Cannot find device|No such container' "${log_file}"; then
    cat >&2 <<EOF
FATAL VM-backed Containerlab validation emitted runtime errors.

Full runtime log: ${log_file}

Open the full log; do not rely on filtered excerpts for root cause.
EOF
    return 1
  fi
}
