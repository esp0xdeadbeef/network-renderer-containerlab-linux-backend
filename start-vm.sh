#!/usr/bin/env bash
set -euo pipefail

# CMC: FS-310 — renderer consumes ONLY CPM output, never intent/inventory
# start-vm.sh accepts a pre-built CPM JSON file.
# emulationSubnets: accepted as env var from the calling environment (not read from raw inventory).
# Renderer inventory: extracted from CPM endpointInventory (not re-imported from inventory-clab.nix).

cpm_json="${1:-}"
if [[ -z "${cpm_json}" || ! -f "${cpm_json}" ]]; then
  echo "Usage: $0 <path-to-cpm-output.json>" >&2
  echo "  Pre-build the CPM JSON externally:" >&2
  echo "    nix run path:network-control-plane-model#compile-and-build-control-plane-model -- \\" >&2
  echo "      --input intent.nix --inventory inventory-clab.nix \\" >&2
  echo "      --emulation-subnets '\"\${EMULATION_SUBNETS:-[]}\"' > cpm.json" >&2
  exit 1
fi

ssh_port="${CLAB_VM_SSH_PORT:-2222}"
ssh_host="${CLAB_VM_SSH_HOST:-127.0.0.1}"
vm_state_dir="${CLAB_VM_STATE_DIR:-}"
ephemeral_vm_state_dir=""

if [[ -z "${vm_state_dir}" ]]; then
  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend/start-vm"
  mkdir -p "${cache_root}"
  ephemeral_vm_state_dir="$(mktemp -d "${cache_root}/state.XXXXXX")"
  vm_state_dir="${ephemeral_vm_state_dir}"
fi

cleanup() {
  if [[ -n "${ephemeral_vm_state_dir}" ]]; then
    rm -rf "${ephemeral_vm_state_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

export QEMU_NET_OPTS="hostfwd=tcp:${ssh_host}:${ssh_port}-:22"
echo "ssh -o 'StrictHostKeyChecking no' -p${ssh_port} root@${ssh_host} # to connect to the vm."

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_WORK_DIR="${vm_state_dir}"

# Some local path-based flake evaluations expect this renderer scratch dir to
# exist even though it is not tracked in git.
mkdir -p "${FLAKE_DIR}/clab-fabric"

mkdir -p "${VM_WORK_DIR}"

if [[ "${VM_WORK_DIR}" != "${FLAKE_DIR}" ]]; then
  cp "${FLAKE_DIR}/vm.nix" "${VM_WORK_DIR}/vm.nix"
  cp "${FLAKE_DIR}/vm-network.nix" "${VM_WORK_DIR}/vm-network.nix"
  cp "${FLAKE_DIR}/vm-network-nat.nix" "${VM_WORK_DIR}/vm-network-nat.nix"
fi

TOPO_FILE="${VM_WORK_DIR}/fabric.clab.yml"
BRIDGES_FILE="${VM_WORK_DIR}/vm-bridges-generated.nix"
VM_NIX="${VM_WORK_DIR}/vm.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Copy the pre-built CPM JSON into the work area
cp "${cpm_json}" "${tmp_dir}/cpm.json"

echo "[*] Extracting renderer inventory from CPM endpointInventory..."
renderer_inv="${tmp_dir}/renderer-inventory.json"
if ! jq -e '.endpointInventory' "${tmp_dir}/cpm.json" > "${renderer_inv}" 2>/dev/null; then
  echo "[!] CPM output missing endpointInventory — cannot extract renderer inventory." >&2
  echo "    The CPM must emit endpointInventory for renderer consumption (SMS-100)." >&2
  exit 1
fi

echo "[*] Rendering Containerlab topology + bridges..."
CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run .#generate-clab-config -- \
  "${tmp_dir}/cpm.json" \
  "${TOPO_FILE}" \
  "${BRIDGES_FILE}" >/dev/null

echo "[*] Starting VM via nixos-shell (preserving custom options)..."
(
  cd "${VM_WORK_DIR}"
  CLAB_VM_BRIDGES_FILE="${BRIDGES_FILE}" \
    nix run --extra-experimental-features 'nix-command flakes' nixpkgs#nixos-shell -- "${VM_NIX}"
)
