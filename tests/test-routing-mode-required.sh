#!/usr/bin/env bash
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-001
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-004
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-005
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-CMC-001-001
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-CMC-001-004
# GAMP-ID: USR-MODEL-001-FS-001-HDS-003-SDS-001-003-SMS-001-CMC-001-005
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-025
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

example_dir="${labs_path}/examples/single-wan"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
  "${example_dir}/intent.nix" \
  "${example_dir}/inventory-clab.nix" \
  "${tmp_dir}/cpm.json" >/dev/null

jq '
  (.control_plane_model.data | to_entries[0].key) as $enterprise
  | (.control_plane_model.data[$enterprise] | to_entries[0].key) as $site
  | (.control_plane_model.data[$enterprise][$site].runtimeTargets | keys[0]) as $target
  | del(.control_plane_model.data[$enterprise][$site].runtimeTargets[$target].routingMode)
' "${tmp_dir}/cpm.json" > "${tmp_dir}/missing-routing-mode.json"

jq '
  (.control_plane_model.data | to_entries[0].key) as $enterprise
  | (.control_plane_model.data[$enterprise] | to_entries[0].key) as $site
  | (.control_plane_model.data[$enterprise][$site].runtimeTargets | keys[0]) as $target
  | .control_plane_model.data[$enterprise][$site].runtimeTargets[$target].routingMode = "role-default"
' "${tmp_dir}/cpm.json" > "${tmp_dir}/invalid-routing-mode.json"

renderer_inv="${tmp_dir}/renderer-inventory.json"
nix eval --impure --json --expr \
  "import ${example_dir}/inventory-clab.nix" \
  > "${renderer_inv}"

set +e
(
  cd "${repo_root}"
  CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/missing-routing-mode.json" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/vm-bridges-generated.nix"
) >"${tmp_dir}/stdout.log" 2>"${tmp_dir}/stderr.log"
rc=$?
set -e

if [[ "${rc}" -eq 0 ]]; then
  echo "FAIL routing-mode-required: renderer accepted missing routingMode" >&2
  exit 1
fi

if ! grep -q "must include routingMode" "${tmp_dir}/stderr.log"; then
  echo "FAIL routing-mode-required: expected routingMode error" >&2
  cat "${tmp_dir}/stderr.log" >&2
  exit 1
fi

set +e
(
  cd "${repo_root}"
  CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/invalid-routing-mode.json" \
    "${tmp_dir}/fabric-invalid.clab.yml" \
    "${tmp_dir}/vm-bridges-invalid.nix"
) >"${tmp_dir}/stdout-invalid.log" 2>"${tmp_dir}/stderr-invalid.log"
rc=$?
set -e

if [[ "${rc}" -eq 0 ]]; then
  echo "FAIL routing-mode-required: renderer accepted invalid routingMode" >&2
  exit 1
fi

if ! grep -q "invalid routingMode" "${tmp_dir}/stderr-invalid.log"; then
  echo "FAIL routing-mode-required: expected invalid routingMode error" >&2
  cat "${tmp_dir}/stderr-invalid.log" >&2
  exit 1
fi

echo "PASS routing-mode-required"
