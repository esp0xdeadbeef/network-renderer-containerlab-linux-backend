#!/usr/bin/env bash
set -euo pipefail

ssh_vm_ready() {
  ssh "${ssh_opts[@]}" "root@${vm_ssh_host}" true >/dev/null 2>&1
}

ssh_vm() {
  local attempts="${VM_SSH_ATTEMPTS:-10}"
  local delay="${VM_SSH_DELAY_SECONDS:-2}"
  local try
  local remote_cmd="$*"

  for try in $(seq 1 "$attempts"); do
    if printf '%s\n' "set -euo pipefail" "$remote_cmd" \
      | ssh "${ssh_opts[@]}" "root@${vm_ssh_host}" /run/current-system/sw/bin/bash --noprofile --norc -s
    then
      return 0
    fi

    if [[ "$try" -lt "$attempts" ]]; then
      sleep "$delay"
    fi
  done

  return 1
}

ssh_vm_once() {
  local remote_cmd="$*"
  printf '%s\n' "set -euo pipefail" "$remote_cmd" \
    | ssh "${ssh_opts[@]}" "root@${vm_ssh_host}" /run/current-system/sw/bin/bash --noprofile --norc -s
}

wait_for_ssh() {
  local deadline=$((SECONDS + ${VM_SSH_WAIT_SECONDS:-600}))

  while (( SECONDS < deadline )); do
    if ssh_vm_ready; then
      return 0
    fi
    if [[ -n "${vm_launcher_pid:-}" ]] && ! kill -0 "${vm_launcher_pid}" >/dev/null 2>&1; then
      wait "${vm_launcher_pid}" || return 1
      return 1
    fi
    sleep 2
  done

  return 1
}

scp_vm_file() {
  local src="$1"
  local dst="$2"
  scp "${scp_opts[@]}" "${src}" "root@${vm_ssh_host}:${dst}" >/dev/null
}
