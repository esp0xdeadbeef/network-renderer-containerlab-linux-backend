#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

workers="${CLAB_VM_MATRIX_WORKERS:-6}"
worker_memory_mb="${CLAB_VM_MATRIX_MEMORY_MB:-4096}"
worker_cores="${CLAB_VM_MATRIX_CORES:-4}"
matrix_root="${CLAB_VM_MATRIX_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend/clab-vm-matrix}"
host_cache_dir="${CLAB_VM_HOST_CACHE_DIR:-${matrix_root}/host-cache}"

labs_path="$(resolve_input_path network-labs)"
mkdir -p "${matrix_root}"

mapfile -t examples < <(
  find "${labs_path}/examples" -mindepth 2 -maxdepth 2 -type f -name 'inventory-clab.nix' -printf '%h\n' \
    | while read -r dir; do
        if [[ -f "${dir}/intent.nix" ]]; then
          basename "${dir}"
        fi
      done \
    | sort
)

if [[ "$#" -gt 0 ]]; then
  examples=("$@")
fi

pids=()
logs=()
worker_ids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

start_worker() {
  local worker="$1"
  shift
  local state_dir
  local log_file
  local ssh_port

  state_dir="$(mktemp -d "${matrix_root}/worker-${worker}.state.XXXXXX")"
  log_file="$(mktemp "${matrix_root}/worker-${worker}.XXXXXX.log")"
  ssh_port=$((2222 + worker))
  logs+=("${log_file}")
  worker_ids+=("${worker}")

  printf '[vm-matrix] worker %s examples: %s\n' "${worker}" "$*"
  printf '[vm-matrix] worker %s ssh port: %s\n' "${worker}" "${ssh_port}"
  printf '[vm-matrix] worker %s log: %s\n' "${worker}" "${log_file}"

  (
    set -euo pipefail
    export CLAB_VM_SSH_PORT="${ssh_port}"
    export CLAB_VM_STATE_DIR="${state_dir}"
    export CLAB_VM_WORKER_ID="${worker}"
    export CLAB_VM_MEMORY_MB="${worker_memory_mb}"
    export CLAB_VM_CORES="${worker_cores}"
    export CLAB_VM_HOST_CACHE_DIR="${host_cache_dir}"
    export NETWORK_INPUT_PATH_NETWORK_LABS="${labs_path}"
    export XDG_CACHE_HOME="${state_dir}/.cache"
    export TMPDIR="${state_dir}/tmp"
    mkdir -p "${XDG_CACHE_HOME}" "${TMPDIR}"
    cd "${repo_root}"
    stdbuf -oL -eL bash tests/FS-780-HDS-010-SDS-010-SMS-010.sh "$@"
  ) > "${log_file}" 2>&1 &
  pids+=("$!")
}

for worker in $(seq 0 $((workers - 1))); do
  subset=()
  idx=0
  for example in "${examples[@]}"; do
    if [[ $((idx % workers)) -eq "$worker" ]]; then
      subset+=("$example")
    fi
    idx=$((idx + 1))
  done

  if [[ "${#subset[@]}" -gt 0 ]]; then
    start_worker "${worker}" "${subset[@]}"
  fi
done

status=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  if ! wait "$pid"; then
    printf '[vm-matrix] worker %s failed; log: %s\n' "${worker_ids[$i]}" "${logs[$i]}" >&2
    status=1
  else
    printf '[vm-matrix] worker %s passed; log: %s\n' "${worker_ids[$i]}" "${logs[$i]}"
  fi
done

trap - EXIT

if [[ "${status}" -ne 0 ]]; then
  printf '[vm-matrix] one or more workers failed. Worker logs:\n' >&2
  printf '  %s\n' "${logs[@]}" >&2
  exit 1
fi

printf '[vm-matrix] PASS all workers\n'
