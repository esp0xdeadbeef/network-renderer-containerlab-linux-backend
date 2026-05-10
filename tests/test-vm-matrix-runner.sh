#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${repo_root}/tests/run-vm-example-matrix.sh"

grep -F 'workers="${CLAB_VM_MATRIX_WORKERS:-6}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must default to six workers" >&2
  exit 1
}

grep -F 'CLAB_VM_MEMORY_MB="${worker_memory_mb}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must pass per-worker memory to vm.nix" >&2
  exit 1
}

grep -F 'CLAB_VM_CORES="${worker_cores}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must pass per-worker cores to vm.nix" >&2
  exit 1
}

grep -F 'NETWORK_INPUT_PATH_NETWORK_LABS="${labs_path}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must pass the resolved labs path to workers" >&2
  exit 1
}

grep -F 'tee "${log_file}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must stream worker output into the parent log" >&2
  exit 1
}

grep -F 'one or more workers failed. Full logs:' "${runner}" >/dev/null || {
  echo "VM matrix runner must point at full worker logs on failure" >&2
  exit 1
}

echo "PASS vm-matrix-runner"
