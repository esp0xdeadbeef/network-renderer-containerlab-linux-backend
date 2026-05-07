#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"
source "${repo_root}/tests/lib/example-output-contract.sh"

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

examples_root="${labs_path}/examples"

log() { echo "==> $*"; }
fail() { echo "$1" >&2; exit 1; }

run_one_example() {
  local dir="$1"
  local name
  local intent
  local inventory

  name="$(basename "${dir}")"
  intent="${dir}/intent.nix"
  inventory="${dir}/inventory-clab.nix"

  [[ -f "${intent}" ]] || { echo "SKIP ${name} (no intent.nix)"; return 0; }
  [[ -f "${inventory}" ]] || { echo "SKIP ${name} (no inventory-clab.nix)"; return 0; }

  log "Example ${name}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local stderr_file
  stderr_file="${tmp_dir}/stderr.log"
  local renderer_inv
  renderer_inv="${tmp_dir}/renderer-inventory.json"
  trap 'rm -rf "'"${tmp_dir}"'"' RETURN

  # Some upstream tools write debug artifacts to CWD. Keep tests reproducible and
  # keep this repo clean by running CPM build inside the temp directory.
  (
    cd "${tmp_dir}"
    nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
      "${intent}" \
      "${inventory}" \
      "${tmp_dir}/cpm.json" >/dev/null 2>"${stderr_file}" \
      || { echo "--- STDERR (${name}) ---"; cat "${stderr_file}"; fail "FAIL ${name}: CPM build failed"; }
  )

  # Run the renderer from the repo root to avoid spurious "not a git repository"
  # noise from Nix when evaluating a path-based flake.
  (
    cd "${repo_root}"
    nix eval --impure --json --expr "import ${inventory}" > "${renderer_inv}"
    CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inv}" nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
      "${tmp_dir}/cpm.json" \
      "${tmp_dir}/fabric.clab.yml" \
      "${tmp_dir}/vm-bridges-generated.nix" >/dev/null 2>"${stderr_file}" \
      || { echo "--- STDERR (${name}) ---"; cat "${stderr_file}"; fail "FAIL ${name}: renderer failed"; }
  )

  if grep -qE 'WARNING|cannot be mapped to any policy interface tag|injected to the config' "${stderr_file}"; then
    echo "--- STDERR (${name}) ---"
    cat "${stderr_file}"
    fail "FAIL ${name}: renderer emitted warning output"
  fi

  test -s "${tmp_dir}/fabric.clab.yml" || fail "FAIL ${name}: missing fabric.clab.yml"
  test -s "${tmp_dir}/vm-bridges-generated.nix" || fail "FAIL ${name}: missing vm-bridges-generated.nix"

  "${repo_root}/tests/validate-rendered-artifacts.sh" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/vm-bridges-generated.nix" \
    || fail "FAIL ${name}: rendered artifact validation failed"

  "${repo_root}/tests/validate-topology-conformance.sh" \
    "${tmp_dir}/cpm.json" \
    "${renderer_inv}" \
    "${tmp_dir}/fabric.clab.yml" \
    || fail "FAIL ${name}: topology conformance validation failed"

  assert_clab_example_output_contract \
    "${name}" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/vm-bridges-generated.nix"

  echo "PASS ${name}"

  rm -rf "${tmp_dir}"
  trap - RETURN
}

log "Scanning examples under: ${examples_root}"
while read -r dir; do
  run_one_example "${dir}"
done < <(find "${examples_root}" -mindepth 1 -maxdepth 1 -type d | sort)

exit 0
