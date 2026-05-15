#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-overlay-dns-lane-policy" "${tmp_dir}"

jq '
  .containerlab.targetHost = "s-router-test"
  | .realization.nodes |= with_entries(
      if (.value.logicalNode.site // "") == "site-b"
      then .value.host = "other-host"
      else .
      end
    )
' "${tmp_dir}/renderer-inventory.json" > "${tmp_dir}/renderer-inventory-filtered.json"

CLABGEN_RENDERER_INVENTORY_JSON="${tmp_dir}/renderer-inventory-filtered.json" \
  CLABGEN_DEPLOYMENT_HOST="s-router-test" \
  nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/cpm.json" \
    "${tmp_dir}/filtered.clab.yml" \
    "${tmp_dir}/filtered-bridges.nix" >/dev/null

if rg -q 'espbranch-site-b-' "${tmp_dir}/filtered.clab.yml"; then
  echo "FAIL deployment-host-filter: renderer emitted site-b nodes assigned to other-host" >&2
  exit 1
fi

if ! rg -q 'esp0xdeadbeef-site-a-' "${tmp_dir}/filtered.clab.yml"; then
  echo "FAIL deployment-host-filter: renderer dropped target-host site-a nodes" >&2
  exit 1
fi

echo "PASS deployment-host-filter"
