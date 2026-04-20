#!/usr/bin/env bash
set -euo pipefail

example="${1:-single-wan}"

export QEMU_NET_OPTS="hostfwd=tcp::2222-:22"
echo "ssh -o 'StrictHostKeyChecking no' -p2222 root@localhost # to connect to the vm."

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOPO_FILE="${FLAKE_DIR}/fabric.clab.yml"
BRIDGES_FILE="${FLAKE_DIR}/vm-bridges-generated.nix"

resolve_input_path() {
  local input_name="$1"
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

if [[ ! -f "${inventory_path}" ]]; then
  inventory_path="${labs_path}/examples/${example}/inventory.nix"
fi

if [[ ! -f "${intent_path}" || ! -f "${inventory_path}" ]]; then
  echo "[!] Missing example inputs:" >&2
  echo "    intent:     ${intent_path}" >&2
  echo "    inventory:  ${inventory_path}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "[*] Building control-plane model from flake-locked network-labs (${example})..."
(
  # Some upstream tools write debug artifacts to CWD; keep this repo clean.
  cd "${tmp_dir}"
  nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${tmp_dir}/cpm.json" >/dev/null
)

echo "[*] Rendering Containerlab topology + bridges..."
renderer_inv="${tmp_dir}/renderer-inventory.json"
nix eval --impure --json --expr "let inv = import ${inventory_path}; in { containerlab = inv.containerlab or {}; }" > "${renderer_inv}"

CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run .#generate-clab-config -- \
  "${tmp_dir}/cpm.json" \
  "${TOPO_FILE}" \
  "${BRIDGES_FILE}" >/dev/null

echo "[*] Starting VM via nixos-shell (preserving custom options)..."
nix run --extra-experimental-features 'nix-command flakes' nixpkgs#nixos-shell -- "${FLAKE_DIR}/vm.nix"
