#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

fail() { echo "$*" >&2; exit 1; }
pass() { echo "PASS $*"; }

render_clab_example() {
  local example_name="$1"
  local tmp_dir="$2"

  local labs_path
  local cpm_path
  labs_path="$(resolve_input_path network-labs)"
  cpm_path="$(resolve_input_path network-control-plane-model)"

  local example_dir
  example_dir="$(resolve_labs_model_dir "${labs_path}" "${example_name}")"
  local intent_path="${example_dir}/intent.nix"
  local inventory_path="${example_dir}/inventory-clab.nix"
  local resolved_inventory_path="${tmp_dir}/inventory-clab-resolved.nix"

  [[ -f "${intent_path}" ]] || fail "missing intent: ${intent_path}"
  [[ -f "${inventory_path}" ]] || fail "missing inventory-clab: ${inventory_path}"

  if [[ -f "${example_dir}/getResolvedInventory.nix" ]]; then
    cat >"${resolved_inventory_path}" <<EOF
import ${example_dir}/getResolvedInventory.nix { renderer = "clab"; }
EOF
    inventory_path="${resolved_inventory_path}"
  fi

  (
    cd "${tmp_dir}"
    nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
      "${intent_path}" \
      "${inventory_path}" \
      "${tmp_dir}/cpm.json" >/dev/null
  )

  (
    cd "${repo_root}"
    nix eval --impure --json --expr \
      "import ${inventory_path}" \
      > "${tmp_dir}/renderer-inventory.json"

    CLABGEN_RENDERER_INVENTORY_JSON="${tmp_dir}/renderer-inventory.json" \
      nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
        "${tmp_dir}/cpm.json" \
        "${tmp_dir}/fabric.clab.yml" \
        "${tmp_dir}/vm-bridges-generated.nix" >/dev/null
  )
}

node_block() {
  local topology="$1"
  local node="$2"

  awk -v node="    ${node}:" '
    $0 == node { in_node = 1; print; next }
    in_node && /^    [^ ].*:$/ { exit }
    in_node { print }
  ' "${topology}"
}

assert_node_contains() {
  local topology="$1"
  local node="$2"
  local needle="$3"
  local block

  block="$(node_block "${topology}" "${node}")"

  if ! grep -Fq -- "${needle}" <<<"${block}"; then
    echo "missing in ${node}: ${needle}" >&2
    echo "--- ${node} ---" >&2
    printf '%s\n' "${block}" >&2
    exit 1
  fi
}

assert_node_matches() {
  local topology="$1"
  local node="$2"
  local regex="$3"
  local block

  block="$(node_block "${topology}" "${node}")"

  if ! REGEX="${regex}" perl -0ne 'exit($_ =~ /$ENV{REGEX}/m ? 0 : 1)' <<<"${block}"; then
    echo "missing in ${node}: regex ${regex}" >&2
    echo "--- ${node} ---" >&2
    printf '%s\n' "${block}" >&2
    exit 1
  fi
}

assert_topology_contains() {
  local topology="$1"
  local needle="$2"

  grep -Fq -- "${needle}" "${topology}" || fail "missing topology text: ${needle}"
}

assert_topology_absent() {
  local topology="$1"
  local needle="$2"

  if grep -Fq -- "${needle}" "${topology}"; then
    fail "unexpected topology text: ${needle}"
  fi
}
