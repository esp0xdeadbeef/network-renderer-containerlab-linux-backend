#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ./run-all-inputs-clab-generator.sh [out-root]

Behavior:
  - For each lab under network-labs/examples/*:
      intent.nix + inventory-clab.nix
        -> builds output-control-plane-model.json (via network-control-plane-model)
        -> renders fabric.clab.yml + vm-bridges-generated.nix (this repo)

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_root="${1:-$(mktemp -d "${TMPDIR:-/tmp}/clabgen-all.XXXXXX")}"

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
        throw "run-all-inputs-clab-generator: missing archived input path for " + name
      else
        p
  '

  rm -f "${archive_json}"
}

# Prefer flake-locked inputs, to keep a stable backlog of which inputs were run.
labs_root="${LABS_ROOT:-}"
if [[ -z "${labs_root}" ]]; then
  labs_root="$(resolve_input_path network-labs)/examples"
fi
if [[ ! -d "$labs_root" ]]; then
  echo "[!] Missing labs examples root: ${labs_root}" >&2
  exit 1
fi

run_cpm_build() {
  local intent="$1"
  local inventory="$2"
  local out="$3"

  local cpm_path
  cpm_path="$(resolve_input_path network-control-plane-model)"
  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${cpm_path}\";
      lib = flake.lib.\"\${builtins.currentSystem}\";
      intent = import \"$(realpath "$intent")\";
      inventory = import \"$(realpath "$inventory")\";
      result = lib.compileAndBuild {
        input = intent;
        inherit inventory;
      };
    in
      result
  " > "$out"
}

mkdir -p "$out_root"

for example_dir in "$labs_root"/*; do
  [[ -d "$example_dir" ]] || continue

  name="$(basename "$example_dir")"
  intent="$example_dir/intent.nix"
  inventory="$example_dir/inventory-clab.nix"

  [[ -f "$intent" ]] || { echo "[!] SKIP ${name}: missing intent.nix" >&2; continue; }
  [[ -f "$inventory" ]] || { echo "[!] SKIP ${name}: missing inventory-clab.nix" >&2; continue; }

  echo "[*] ${name}"

  (
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clabgen.${name}.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT

    cpm_json="$tmp_dir/output-control-plane-model.json"
    topo_out="$out_root/$name/fabric.clab.yml"
    bridges_out="$out_root/$name/vm-bridges-generated.nix"

    mkdir -p "$out_root/$name"

    run_cpm_build "$intent" "$inventory" "$cpm_json"

    nix run "path:${repo_root}#generate-clab-config" -- "$cpm_json" "$topo_out" "$bridges_out" >/dev/null
    "${repo_root}/tests/validate-rendered-artifacts.sh" "$topo_out" "$bridges_out"

    echo "    - $topo_out"
    echo "    - $bridges_out"
  )
done
