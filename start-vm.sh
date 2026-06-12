#!/usr/bin/env bash
set -euo pipefail

example="${1:-single-wan}"

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

resolve_input_path() {
  local input_name="$1"
  local override_var
  local override_path
  override_var="NETWORK_INPUT_PATH_${input_name^^}"
  override_var="${override_var//-/_}"
  override_path="${!override_var:-}"
  if [[ -n "${override_path}" ]]; then
    [[ -d "${override_path}" ]] || {
      echo "start-vm: invalid ${override_var} for ${input_name}: ${override_path}" >&2
      exit 1
    }
    printf '%s\n' "${override_path}"
    return 0
  fi

  local archive_json
  archive_json="$(mktemp)"

  nix flake archive --json "path:${FLAKE_DIR}" > "${archive_json}"

  INPUT_NAME="${input_name}" ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      name = builtins.getEnv "INPUT_NAME";
      input = archived.inputs.${name} or null;
      p = if input == null then null else input.path or null;
    in
      if p == null then
        throw "start-vm: missing archived input path for " + name
      else
        p
  '

  rm -f "${archive_json}"
}

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

intent_path="${labs_path}/examples/${example}/intent.nix"
inventory_path="${labs_path}/examples/${example}/inventory-clab.nix"

if [[ ! -f "${intent_path}" || ! -f "${inventory_path}" ]]; then
  echo "[!] Missing example inputs:" >&2
  echo "    intent:     ${intent_path}" >&2
  echo "    inventory:  ${inventory_path}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "[*] Building control-plane model from resolved network-labs input (${example})..."
(
  # Some upstream tools write debug artifacts to CWD; keep this repo clean.
  cd "${tmp_dir}"
  # Pass emulationSubnets from inventory to CPM (FS-260-HDS-010-SDS-010-SMS-012)
  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${cpm_path}\";
      lib = flake.lib.\"\${builtins.currentSystem}\";
      intent = import \"$(realpath "${intent_path}")\";
      inventory = import \"$(realpath "${inventory_path}")\";
      result = lib.compileAndBuild {
        input = intent;
        inherit inventory;
        emulationSubnets = inventory.hat.emulationSubnets or [];
      };
    in
      result
  " > "${tmp_dir}/cpm.json"
)

echo "[*] Rendering Containerlab topology + bridges..."
renderer_inv="${tmp_dir}/renderer-inventory.json"
nix eval --impure --json --expr "import ${inventory_path}" > "${renderer_inv}"

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
