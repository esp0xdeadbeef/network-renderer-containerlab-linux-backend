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

grep -F 'CLAB_VM_HOST_CACHE_DIR="${host_cache_dir}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must share the host Docker image cache across workers" >&2
  exit 1
}

grep -F 'NETWORK_INPUT_PATH_NETWORK_LABS="${labs_path}"' "${runner}" >/dev/null || {
  echo "VM matrix runner must pass the resolved labs path to workers" >&2
  exit 1
}

grep -F 'override_var="NETWORK_INPUT_PATH_${input_name^^}"' "${repo_root}/start-vm.sh" >/dev/null || {
  echo "start-vm must honor NETWORK_INPUT_PATH_* overrides when rendering the VM topology" >&2
  exit 1
}

grep -F 'cp "${FLAKE_DIR}/vm-network.nix" "${VM_WORK_DIR}/vm-network.nix"' "${repo_root}/start-vm.sh" >/dev/null || {
  echo "start-vm must copy vm-network.nix next to vm.nix in isolated worker state" >&2
  exit 1
}

grep -F 'cp "${FLAKE_DIR}/vm-network-nat.nix" "${VM_WORK_DIR}/vm-network-nat.nix"' "${repo_root}/start-vm.sh" >/dev/null || {
  echo "start-vm must copy vm-network-nat.nix next to vm.nix in isolated worker state" >&2
  exit 1
}

grep -F ') > "${log_file}" 2>&1 &' "${runner}" >/dev/null || {
  echo "VM matrix runner must bind each worker stdout to its own log" >&2
  exit 1
}

if grep -F 'sed -u "s/^/[worker-${worker}] /"' "${runner}" >/dev/null; then
  echo "VM matrix runner must not multiplex worker stdout through the parent stream" >&2
  exit 1
fi

grep -F 'one or more workers failed. Worker logs:' "${runner}" >/dev/null || {
  echo "VM matrix runner must point at worker-bound logs on failure" >&2
  exit 1
}

echo "PASS vm-matrix-runner"
