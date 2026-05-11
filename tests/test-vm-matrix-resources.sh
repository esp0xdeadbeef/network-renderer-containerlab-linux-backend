#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matrix_script="${repo_root}/tests/start-vm-example-matrix-tmux.sh"
vm_nix="${repo_root}/vm.nix"

grep -F 'workers="${CLAB_VM_MATRIX_WORKERS:-6}"' "${matrix_script}" >/dev/null || {
  echo "FAIL vm matrix resources: matrix must default to six workers" >&2
  exit 1
}

grep -F 'examples=("$@")' "${matrix_script}" >/dev/null || {
  echo "FAIL vm matrix resources: matrix must allow focused example runs" >&2
  exit 1
}

grep -F 'worker_memory_mb="${CLAB_VM_MATRIX_MEMORY_MB:-4096}"' "${matrix_script}" >/dev/null || {
  echo "FAIL vm matrix resources: matrix must default each worker to 4096 MB" >&2
  exit 1
}

grep -F 'worker_cores="${CLAB_VM_MATRIX_CORES:-4}"' "${matrix_script}" >/dev/null || {
  echo "FAIL vm matrix resources: matrix must default each worker to 4 cores" >&2
  exit 1
}

grep -F 'export CLAB_VM_MEMORY_MB' "${matrix_script}" >/dev/null
grep -F 'export CLAB_VM_CORES' "${matrix_script}" >/dev/null
grep -F 'export CLAB_VM_WORKER_ID' "${matrix_script}" >/dev/null
grep -F 'export CLAB_VM_HOST_CACHE_DIR' "${matrix_script}" >/dev/null
grep -F 'clab-worker-${w}' "${matrix_script}" >/dev/null
grep -F 'tmux new-window -t "${session}" -n "clab-worker-${w}"' "${matrix_script}" >/dev/null
grep -F 'exec > >(tee -a "$log_file") 2>&1' "${matrix_script}" >/dev/null
grep -F 'builtins.getEnv "CLAB_VM_MEMORY_MB"' "${vm_nix}" >/dev/null
grep -F 'builtins.getEnv "CLAB_VM_CORES"' "${vm_nix}" >/dev/null
grep -F 'virtualisation.memorySize = vmMemorySize;' "${vm_nix}" >/dev/null
grep -F 'virtualisation.cores = vmCores;' "${vm_nix}" >/dev/null

echo "PASS vm-matrix-resources"
