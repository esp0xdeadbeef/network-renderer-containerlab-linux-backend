#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

fail() { echo "$1" >&2; exit 1; }

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
example_dir="${labs_path}/examples/single-wan-uplink-ebgp"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-clab.nix"

[[ -f "${intent_path}" ]] || fail "missing intent.nix: ${intent_path}"
[[ -f "${inventory_path}" ]] || fail "missing inventory-clab.nix: ${inventory_path}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

(
  cd "${tmp_dir}"
  nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${tmp_dir}/cpm.json" >/dev/null
)

(
  cd "${repo_root}"
  renderer_inv="${tmp_dir}/renderer-inventory.json"
  nix eval --impure --json --expr "let inv = import ${inventory_path}; in { containerlab = inv.containerlab or {}; }" > "${renderer_inv}"
  CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/cpm.json" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/vm-bridges-generated.nix" >/dev/null
)

"${repo_root}/tests/validate-rendered-artifacts.sh" \
  "${tmp_dir}/fabric.clab.yml" \
  "${tmp_dir}/vm-bridges-generated.nix"

grep -q 'router bgp 65000' "${tmp_dir}/fabric.clab.yml" || fail "missing site ASN in generated BGP config"
grep -q 'neighbor 203.0.113.1 remote-as 64512' "${tmp_dir}/fabric.clab.yml" || fail "missing eBGP neighbor in generated topology"
grep -q 'neighbor 10.19.0.5 remote-as 65000' "${tmp_dir}/fabric.clab.yml" || fail "missing iBGP neighbor in generated topology"
grep -q 'route-reflector-client' "${tmp_dir}/fabric.clab.yml" || fail "missing route-reflector client configuration"
grep -q 'network 10.20.10.0/24' "${tmp_dir}/fabric.clab.yml" || fail "missing tenant IPv4 advertisement"

echo "PASS single-wan-uplink-ebgp"
