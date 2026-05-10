#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"
source "${repo_root}/tests/lib/vm-runtime-log-guard.sh"
vm_ssh_port="${CLAB_VM_SSH_PORT:-2222}"
vm_ssh_host="${CLAB_VM_SSH_HOST:-127.0.0.1}"
vm_state_dir="${CLAB_VM_STATE_DIR:-}"
ephemeral_vm_state_dir=""
host_cache_root="${CLAB_VM_HOST_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend}"
host_image_cache_tar="${host_cache_root}/clab-frr-plus-tooling-latest.tar"
host_image_cache_id="${host_cache_root}/clab-frr-plus-tooling-latest.image-id"
host_image_cache_lock="${host_cache_root}/clab-frr-plus-tooling.lock"
vm_image_cache_tar="/var/tmp/clab-frr-plus-tooling-latest.tar"
vm_image_cache_id="/var/tmp/clab-frr-plus-tooling-latest.image-id"
tooling_image="clab-frr-plus-tooling:latest"
work_root="${CLAB_VM_WORK_ROOT:-${vm_state_dir:-${host_cache_root}/vm-example-work}}"
host_tooling_cache_available=1

if [[ -z "${vm_state_dir}" ]]; then
  runtime_root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  mkdir -p "${runtime_root}/network-renderer-containerlab-linux-backend"
  ephemeral_vm_state_dir="$(mktemp -d "${runtime_root}/network-renderer-containerlab-linux-backend/vm-state.XXXXXX")"
  vm_state_dir="${ephemeral_vm_state_dir}"
  work_root="${CLAB_VM_WORK_ROOT:-${ephemeral_vm_state_dir}/work}"
fi

ssh_opts=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout="${VM_SSH_CONNECT_TIMEOUT_SECONDS:-5}"
  -o ConnectionAttempts=1
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=no
  -o GlobalKnownHostsFile=/dev/null
  -o UserKnownHostsFile=/dev/null
  -o UpdateHostKeys=no
  -p "${vm_ssh_port}"
)

scp_opts=(
  -o BatchMode=yes
  -o ConnectTimeout="${VM_SSH_CONNECT_TIMEOUT_SECONDS:-5}"
  -o ConnectionAttempts=1
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=no
  -o GlobalKnownHostsFile=/dev/null
  -o UserKnownHostsFile=/dev/null
  -o UpdateHostKeys=no
  -P "${vm_ssh_port}"
)

log() {
  printf '[vm-test] %s\n' "$*"
}

source "${repo_root}/tests/lib/vm-ssh-helpers.sh"
source "${repo_root}/tests/lib/vm-tooling-cache.sh"
source "${repo_root}/tests/lib/vm-lifecycle.sh"
source "${repo_root}/tests/lib/vm-cpm-context.sh"
source "${repo_root}/tests/lib/vm-runtime-targets.sh"
source "${repo_root}/tests/lib/vm-example-checks.sh"

discover_examples() {
  local labs_path="$1"

  find "${labs_path}/examples" -mindepth 2 -maxdepth 2 -type f -name 'inventory-clab.nix' -printf '%h\n' \
    | while read -r dir; do
        if [[ -f "${dir}/intent.nix" ]]; then
          basename "${dir}"
        fi
      done \
    | sort
}

run_example() {
  local example="$1"
  local launcher_log
  local validation_log
  local tmp_dir
  local needs_context=0
  mkdir -p "${work_root}"
  launcher_log="$(mktemp "${work_root}/clab-vm-${example}.XXXXXX.log")"
  validation_log="$(mktemp "${work_root}/clab-vm-${example}-runtime.XXXXXX.log")"
  tmp_dir="$(mktemp -d "${work_root}/clab-vm-${example}.XXXXXX")"

  case "$example" in
    single-wan|dual-wan-branch-overlay|dual-wan-branch-overlay-bgp)
      needs_context=1
      ;;
  esac

  log "compiling CPM for ${example}"
  compile_example_cpm "$example" "${tmp_dir}/cpm.json" "$labs_path" "$cpm_path"
  if [[ "${needs_context}" -eq 1 ]]; then
    load_example_context "$example" "${tmp_dir}/cpm.json"
  fi
  cleanup_vm

  log "starting VM for ${example}"
  (
    cd "$repo_root"
    CLAB_VM_STATE_DIR="${vm_state_dir}" ./start-vm.sh "$example" 2>&1 | tee "$launcher_log"
  ) &

  if ! wait_for_ssh; then
    cat "$launcher_log" >&2 || true
    log "VM did not become reachable for ${example}"
    return 1
  fi

  log "running VM-backed validation for ${example}"
  stage_rendered_topology
  run_in_vm_validation "${validation_log}"
  mapfile -t runtime_target_suffixes < <(extract_runtime_target_suffixes "${tmp_dir}/cpm.json")
  if ! check_runtime_target_suffixes_present "${runtime_target_suffixes[@]}"; then
    return 1
  fi
  mapfile -t runtime_dataplane_checks < <(extract_runtime_target_dataplane_checks "${tmp_dir}/cpm.json")
  if ! check_runtime_target_dataplane "${runtime_dataplane_checks[@]}"; then
    return 1
  fi

  case "$example" in
    single-wan)
      log "running single-wan post-check"
      check_single_wan
      ;;
    dual-wan-branch-overlay)
      log "running dual-wan-branch-overlay post-check"
      check_dual_wan_overlay
      ;;
    dual-wan-branch-overlay-bgp)
      log "running dual-wan-branch-overlay-bgp post-check"
      check_dual_wan_overlay_bgp
      ;;
    *)
      log "no bespoke post-check defined for ${example}; runtime target presence only"
      ;;
  esac

  log "PASS ${example}"
  shutdown_vm
  rm -f "$launcher_log"
  rm -f "$validation_log"
  rm -rf "$tmp_dir"
}

trap 'cleanup_vm; cleanup_ephemeral_state' EXIT
log "resolving locked flake inputs"
labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
log "resolved network-labs at ${labs_path}"
log "resolved network-control-plane-model at ${cpm_path}"

if [[ "$#" -gt 0 ]]; then
  examples=("$@")
else
  mapfile -t examples < <(discover_examples "$labs_path")
fi

failures=()

for example in "${examples[@]}"; do
  if ! run_example "$example"; then
    failures+=("$example")
    log "FAIL ${example}"
    cleanup_vm
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  log "failing examples: ${failures[*]}"
  exit 1
fi
