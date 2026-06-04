#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-010-SDS-020-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"
source "${repo_root}/tests/lib/render-clab-example.sh"

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
hat_dir="${labs_path}/HAT/emulated-isp-residential-testnet"
intent_path="${hat_dir}/intent.nix"
inventory_path="${hat_dir}/inventory-clab.nix"

[[ -f "${intent_path}" ]] || fail "missing HAT intent: ${intent_path}"
[[ -f "${inventory_path}" ]] || fail "missing HAT CLAB inventory: ${inventory_path}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

(
  cd "${tmp_dir}"
  nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${tmp_dir}/cpm.json" >/dev/null
)

(
  cd "${repo_root}"
  nix eval --impure --json --expr "import ${inventory_path}" >"${tmp_dir}/renderer-inventory.json"
  CLABGEN_RENDERER_INVENTORY_JSON="${tmp_dir}/renderer-inventory.json" \
    nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
      "${tmp_dir}/cpm.json" \
      "${tmp_dir}/fabric.clab.yml" \
      "${tmp_dir}/vm-bridges-generated.nix" >/dev/null
)

topology="${tmp_dir}/fabric.clab.yml"
node="esp0xdeadbeef-site-b-clab-core-upstream-vlan4"

assert_node_contains "${topology}" "${node}" "ip addr replace"
assert_node_contains "${topology}" "${node}" "udhcpc -b -i ens80"
assert_node_contains "${topology}" "${node}" "net.ipv6.conf.ens80.accept_ra=2"
assert_node_contains "${topology}" "${node}" 'oifname "ens80" masquerade'

echo "PASS hat-upstream-vlan4-wan"
