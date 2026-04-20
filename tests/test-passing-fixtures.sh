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

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

examples_root="${labs_path}/examples"

log() { echo "==> $*"; }
fail() { echo "$1" >&2; exit 1; }

validate_yaml_minimal() {
  local file="$1"
  grep -q '^name:' "${file}" || fail "FAIL: missing top-level 'name:' in ${file}"
  grep -q '^topology:' "${file}" || fail "FAIL: missing top-level 'topology:' in ${file}"
}

run_one_example() {
  local dir="$1"
  local name
  local intent
  local inventory

  name="$(basename "${dir}")"
  intent="${dir}/intent.nix"
  inventory="${dir}/inventory.nix"

  [[ -f "${intent}" ]] || { echo "SKIP ${name} (no intent.nix)"; return 0; }
  [[ -f "${inventory}" ]] || { echo "SKIP ${name} (no inventory.nix)"; return 0; }

  log "Example ${name}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local stderr_file
  stderr_file="${tmp_dir}/stderr.log"
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
    nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
      "${tmp_dir}/cpm.json" \
      "${tmp_dir}/fabric.clab.yml" \
      "${tmp_dir}/vm-bridges-generated.nix" >/dev/null 2>"${stderr_file}" \
      || { echo "--- STDERR (${name}) ---"; cat "${stderr_file}"; fail "FAIL ${name}: renderer failed"; }
  )

  test -s "${tmp_dir}/fabric.clab.yml" || fail "FAIL ${name}: missing fabric.clab.yml"
  test -s "${tmp_dir}/vm-bridges-generated.nix" || fail "FAIL ${name}: missing vm-bridges-generated.nix"

  validate_yaml_minimal "${tmp_dir}/fabric.clab.yml"

  echo "PASS ${name}"

  rm -rf "${tmp_dir}"
  trap - RETURN
}

log "Scanning examples under: ${examples_root}"
while read -r dir; do
  run_one_example "${dir}"
done < <(find "${examples_root}" -mindepth 1 -maxdepth 1 -type d | sort)

exit 0
