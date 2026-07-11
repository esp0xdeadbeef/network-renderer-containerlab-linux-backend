#!/usr/bin/env bash
set -euo pipefail

cleanup_vm() {
  if [[ -n "${vm_state_dir}" ]]; then
    pkill -f "${vm_state_dir}/vm.nix" >/dev/null 2>&1 || true
    pkill -f "qemu-system-x86_64 .*${vm_state_dir}/nixos.qcow2" >/dev/null 2>&1 || true
    rm -f \
      "${vm_state_dir}/fabric.clab.yml" \
      "${vm_state_dir}/vm-bridges-generated.nix" \
      "${vm_state_dir}/run-nixos-vm" \
      "${vm_state_dir}/vm-state.log" \
      >/dev/null 2>&1 || true
  else
    pkill -f "${repo_root}/vm.nix" >/dev/null 2>&1 || true
    pkill -f "qemu-system-x86_64 .*${repo_root}/nixos.qcow2" >/dev/null 2>&1 || true
  fi
  sleep 2
}

cleanup_ephemeral_state() {
  if [[ -n "${ephemeral_vm_state_dir}" ]]; then
    rm -rf "${ephemeral_vm_state_dir}" >/dev/null 2>&1 || true
  fi
}

vm_remote_topology_file="${CLAB_VM_REMOTE_TOPO_FILE:-/tmp/clab-vm/fabric.clab.yml}"

shutdown_vm() {
  ssh_vm 'shutdown -h now' >/dev/null 2>&1 || true
  sleep 5
  cleanup_vm
}

stage_rendered_topology() {
  if [[ -z "${vm_state_dir}" ]]; then
    return 0
  fi

  log "staging rendered topology into the VM"
  ssh_vm_once "mkdir -p '$(dirname "${vm_remote_topology_file}")'"
  scp_vm_file \
    "${vm_state_dir}/fabric.clab.yml" \
    "${vm_remote_topology_file}"
}

run_in_vm_validation() {
  local validation_log="$1"
  local validation_timeout_seconds="${CLAB_VM_VALIDATION_TIMEOUT_SECONDS:-2100}"

  log "running run-in-vm.sh inside the VM"
  stage_tooling_cache_into_vm
  if ! ssh_vm_once "
    set -euo pipefail
    cd '${repo_root}'
    timeout '${validation_timeout_seconds}' env \
      CLAB_TOPO_FILE='${vm_remote_topology_file}' \
      CLAB_DOCKER_WAIT_SECONDS='${CLAB_DOCKER_WAIT_SECONDS:-120}' \
      CLAB_DOCKER_INFO_TIMEOUT_SECONDS='${CLAB_DOCKER_INFO_TIMEOUT_SECONDS:-10}' \
      CLAB_SYSTEMCTL_TIMEOUT_SECONDS='${CLAB_SYSTEMCTL_TIMEOUT_SECONDS:-60}' \
      CLAB_CLEANUP_TIMEOUT_SECONDS='${CLAB_CLEANUP_TIMEOUT_SECONDS:-120}' \
      CLAB_DEPLOY_TIMEOUT_SECONDS='${CLAB_DEPLOY_TIMEOUT_SECONDS:-900}' \
      CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS='${CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS:-180}' \
      CLAB_DEPLOY_ATTEMPTS='${CLAB_DEPLOY_ATTEMPTS:-3}' \
      CLAB_DEPLOY_RETRY_DELAY_SECONDS='${CLAB_DEPLOY_RETRY_DELAY_SECONDS:-5}' \
      CLAB_DEPLOY_MAX_WORKERS='${CLAB_DEPLOY_MAX_WORKERS:-1}' \
      CLAB_CONTAINERLAB_API_TIMEOUT='${CLAB_CONTAINERLAB_API_TIMEOUT:-10m}' \
      CLAB_FRR_TOOLING_CACHE_TAR='${vm_image_cache_tar}' \
      CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE='${vm_image_cache_id}' \
      ./run-in-vm.sh
  " 2>&1 | tee "${validation_log}"; then
    return 1
  fi
  if ! guard_vm_runtime_log "${validation_log}"; then
    return 1
  fi
  log "run-in-vm.sh completed"
}
