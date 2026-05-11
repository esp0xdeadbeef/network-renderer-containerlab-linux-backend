#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/vm-runtime-log-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

clean_log="${tmp_dir}/clean.log"
error_log="${tmp_dir}/error.log"
stderr_file="${tmp_dir}/stderr"

cat >"${clean_log}" <<'EOF'
14:02:00 INFO Containerlab deploy completed
14:02:01 INFO Executed command node=router command="ip link set lo up"
EOF

guard_vm_runtime_log "${clean_log}"

cat >"${error_log}" <<'EOF'
14:02:02 ERRO Failed to execute command command="ip link set eth1 up" node=router rc=1
  stderr=
  | Cannot find device "eth1"
EOF

if guard_vm_runtime_log "${error_log}" 2>"${stderr_file}"; then
  echo "FAIL vm runtime log guard: expected Containerlab ERRO to fail" >&2
  exit 1
fi

grep -F "FATAL VM-backed Containerlab validation emitted runtime errors." "${stderr_file}" >/dev/null
grep -F "Full runtime log: ${error_log}" "${stderr_file}" >/dev/null
grep -F "Open the full log; do not rely on filtered excerpts for root cause." "${stderr_file}" >/dev/null

if grep -F "Cannot find device" "${stderr_file}" >/dev/null; then
  echo "FAIL vm runtime log guard: stderr must point at the full log, not print filtered root-cause guesses" >&2
  exit 1
fi

cat >"${error_log}" <<'EOF'
14:03:00 INFO Parsing & checking topology file=fabric.clab.yml
14:03:00 invalid container name or ID: value is empty
EOF

if guard_vm_runtime_log "${error_log}" 2>"${stderr_file}"; then
  echo "FAIL vm runtime log guard: expected invalid container name log to fail" >&2
  exit 1
fi

grep -F "FATAL VM-backed Containerlab validation emitted runtime errors." "${stderr_file}" >/dev/null
grep -F "Full runtime log: ${error_log}" "${stderr_file}" >/dev/null
grep -F "Open the full log; do not rely on filtered excerpts for root cause." "${stderr_file}" >/dev/null

echo "PASS vm-runtime-log-guard"
