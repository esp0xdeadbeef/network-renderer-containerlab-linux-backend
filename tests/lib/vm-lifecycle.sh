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
  scp_vm_file \
    "${vm_state_dir}/fabric.clab.yml" \
    "${repo_root}/fabric.clab.yml"
}

run_in_vm_validation() {
  local validation_log="$1"

  log "running run-in-vm.sh inside the VM"
  stage_tooling_cache_into_vm
  ssh_vm "
    set -euo pipefail
    cd '${repo_root}'
    timeout 900 env \
      CLAB_TOPO_FILE='${repo_root}/fabric.clab.yml' \
      CLAB_FRR_TOOLING_CACHE_TAR='${vm_image_cache_tar}' \
      CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE='${vm_image_cache_id}' \
      ./run-in-vm.sh
  " 2>&1 | tee "${validation_log}"
  guard_vm_runtime_log "${validation_log}"
  log "run-in-vm.sh completed"
}
