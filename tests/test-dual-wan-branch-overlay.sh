#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_input_path() {
  local input_name="$1"
  local archive_json
  archive_json="$(mktemp)"

  nix flake archive --json "path:${repo_root}" > "${archive_json}"

  INPUT_NAME="${input_name}" ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      name = builtins.getEnv "INPUT_NAME";
      input = archived.inputs.${name} or null;
      p = if input == null then null else input.path or null;
    in
      if p == null then
        throw "tests: missing archived input path for " + name
      else
        p
  '

  rm -f "${archive_json}"
}

fail() { echo "$1" >&2; exit 1; }

resolve_example_dir() {
  local example_name="$1"
  local labs_path="$2"
  local pinned_dir="${labs_path}/examples/${example_name}"
  local sibling_dir="${repo_root}/../network-labs/examples/${example_name}"

  if [[ -f "${pinned_dir}/intent.nix" ]]; then
    printf '%s\n' "${pinned_dir}"
    return 0
  fi

  if [[ -f "${sibling_dir}/intent.nix" ]]; then
    printf '%s\n' "${sibling_dir}"
    return 0
  fi

  fail "missing intent.nix: ${pinned_dir}/intent.nix"
}

run_example() {
  local example_name="$1"
  local labs_path="$2"
  local cpm_path="$3"
  local example_dir
  example_dir="$(resolve_example_dir "${example_name}" "${labs_path}")"
  local intent_path="${example_dir}/intent.nix"
  local inventory_path="${example_dir}/inventory-clab.nix"

  [[ -f "${inventory_path}" ]] || fail "missing inventory-clab.nix: ${inventory_path}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "'"${tmp_dir}"'"' RETURN

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
      "${tmp_dir}/vm-bridges-generated.nix" >"${tmp_dir}/stdout.log" 2>"${tmp_dir}/stderr.log"
  )

  if grep -q 'external has no policy-local tag and no overlay realization' "${tmp_dir}/stderr.log"; then
    cat "${tmp_dir}/stderr.log" >&2
    fail "FAIL ${example_name}: unresolved overlay external warning"
  fi

  if grep -q 'external cannot be mapped to any policy interface tag' "${tmp_dir}/stderr.log"; then
    cat "${tmp_dir}/stderr.log" >&2
    fail "FAIL ${example_name}: overlay external not mapped to policy interface"
  fi

  grep -q 'enterpriseA-site-a-s-router-core-isp-b' "${tmp_dir}/fabric.clab.yml" \
    || fail "FAIL ${example_name}: missing enterpriseA overlay terminator node"
  grep -q 'enterpriseB-site-b-b-router-core' "${tmp_dir}/fabric.clab.yml" \
    || fail "FAIL ${example_name}: missing enterpriseB overlay terminator node"

  if [[ "${example_name}" == *-bgp ]]; then
    grep -q 'router bgp 65000' "${tmp_dir}/fabric.clab.yml" \
      || fail "FAIL ${example_name}: missing site-a BGP ASN"
    grep -q 'router bgp 65100' "${tmp_dir}/fabric.clab.yml" \
      || fail "FAIL ${example_name}: missing site-b BGP ASN"
  fi

  echo "PASS ${example_name}"

  rm -rf "${tmp_dir}"
  trap - RETURN
}

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

run_example "dual-wan-branch-overlay" "${labs_path}" "${cpm_path}"
run_example "dual-wan-branch-overlay-bgp" "${labs_path}" "${cpm_path}"
