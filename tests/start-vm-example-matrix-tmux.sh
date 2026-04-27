#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"
session="${1:-clab-vm-matrix}"
workers="${CLAB_VM_MATRIX_WORKERS:-3}"
matrix_root="${CLAB_VM_MATRIX_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend/clab-vm-matrix}"

cleanup_legacy_tmp_state() {
  find /tmp -maxdepth 1 -type d \
    \( -name 'clab-vm-worker-*' -o -name 'clab-vm-check.*' \) \
    -exec rm -rf {} + 2>/dev/null || true
  find /tmp -maxdepth 1 -type f -name 'clab-vm-worker-*.sh' -delete 2>/dev/null || true
}

labs_path="$(resolve_input_path network-labs)"

mapfile -t examples < <(
  find "${labs_path}/examples" -mindepth 2 -maxdepth 2 -type f -name 'inventory-clab.nix' -printf '%h\n' \
    | while read -r dir; do
        if [[ -f "${dir}/intent.nix" ]]; then
          basename "${dir}"
        fi
      done \
    | sort
)

if tmux has-session -t "${session}" 2>/dev/null; then
  tmux kill-session -t "${session}"
fi

mkdir -p "${matrix_root}"
cleanup_legacy_tmp_state

# tmux has no true "infinite" history; use a very large limit for worker inspection.
tmux set-option -g history-limit 200000 >/dev/null

first=1

for w in $(seq 0 $((workers - 1))); do
  subset=()
  idx=0
  ssh_port=$((2222 + w))
  state_dir="$(mktemp -d "${matrix_root}/worker-${w}.state.XXXXXX")"

  for ex in "${examples[@]}"; do
    if [[ $((idx % workers)) -eq "$w" ]]; then
      subset+=("$ex")
    fi
    idx=$((idx + 1))
  done

  worker_script="$(mktemp "${matrix_root}/worker-${w}.XXXXXX.sh")"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf 'worker_script=%q\n' "${worker_script}"
    printf 'state_dir=%q\n' "${state_dir}"
    echo 'cleanup() {'
    echo '  rm -rf "$state_dir" >/dev/null 2>&1 || true'
    echo '  rm -f "$worker_script" >/dev/null 2>&1 || true'
    echo '}'
    echo 'trap cleanup EXIT'
    printf 'cd %q\n' "${repo_root}"
    printf 'export CLAB_VM_SSH_PORT=%q\n' "${ssh_port}"
    echo 'export CLAB_VM_STATE_DIR="$state_dir"'
    printf 'export XDG_CACHE_HOME=%q\n' "${state_dir}/.cache"
    printf 'export TMPDIR=%q\n' "${state_dir}/tmp"
    printf 'mkdir -p %q %q\n' "${state_dir}/.cache" "${state_dir}/tmp"
    printf 'printf "worker %s examples: %%s\\n" %q\n' "$w" "${subset[*]}"
    printf 'printf "worker %s ssh port: %%s\\n" %q\n' "$w" "${ssh_port}"
    printf 'printf "worker %s state dir: %%s\\n" %q\n' "$w" "${state_dir}"
    echo 'stty sane 2>/dev/null || true'
    echo 'set +e'
    printf 'stdbuf -oL -eL bash tests/test-vm-examples.sh'
    for ex in "${subset[@]}"; do
      printf ' %q' "${ex}"
    done
    printf '\n'
    echo 'status=$?'
    printf 'printf "\\nworker %s exit status: %%s\\n" "$status"\n' "$w"
    echo 'if [[ "$status" -ne 0 ]]; then'
    printf '  printf "worker %s failed; leaving pane open for inspection\\n"\n' "$w"
    echo 'else'
    printf '  printf "worker %s completed successfully; leaving pane open\\n"\n' "$w"
    echo 'fi'
    echo 'exec bash'
  } > "${worker_script}"
  chmod +x "${worker_script}"

  if [[ "${first}" -eq 1 ]]; then
    tmux new-session -d -s "${session}" -n "worker-${w}" "${worker_script}"
    first=0
  else
    tmux new-window -t "${session}" -n "worker-${w}" "${worker_script}"
  fi
done

tmux set-option -t "${session}" remain-on-exit on >/dev/null

tmux list-windows -t "${session}"
