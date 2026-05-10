#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_dir="${repo_root}/clab-fabric"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

if [[ -e "${scratch_dir}" ]]; then
  rmdir "${scratch_dir}" 2>/dev/null \
    || fail "FAIL rendered artifact validator scratch dir: ${scratch_dir} exists and is not empty"
fi

cat > "${tmp_dir}/fabric.clab.yml" <<'EOF'
name: fabric
topology:
  nodes:
    br-a:
      kind: bridge
    node-a:
      kind: linux
  links:
    - endpoints:
        - "br-a:eth1"
        - "node-a:eth1"
      labels:
        clab.link.bridge: br-a
EOF

cat > "${tmp_dir}/vm-bridges-generated.nix" <<'EOF'
{ lib, ... }:
{
  bridges = [ "br-a" ];
  bridgeNetworks = { };
}
EOF

"${repo_root}/tests/validate-rendered-artifacts.sh" \
  "${tmp_dir}/fabric.clab.yml" \
  "${tmp_dir}/vm-bridges-generated.nix"

if [[ -e "${scratch_dir}" ]]; then
  fail "FAIL rendered artifact validator scratch dir: validator left ${scratch_dir} behind"
fi

echo "PASS rendered-artifact-validator-scratch-dir"
