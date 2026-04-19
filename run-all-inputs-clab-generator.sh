#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ./run-all-inputs-clab-generator.sh [out-root]

Behavior:
  - For each lab under network-labs/examples/*:
      intent.nix + inventory.nix
        -> builds output-control-plane-model.json (via network-control-plane-model)
        -> renders fabric.clab.yml + vm-bridges-generated.nix (this repo)

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_root="${1:-$repo_root/out}"

labs_root="${repo_root}/../network-labs/examples"
if [[ ! -d "$labs_root" ]]; then
  echo "[!] Missing ${labs_root}. Clone network-labs next to this repo, or adapt the script." >&2
  exit 1
fi

cpm_repo="${repo_root}/../network-control-plane-model"
cpm_app="github:esp0xdeadbeef/network-control-plane-model#compile-and-build-control-plane-model"
if [[ -d "$cpm_repo" ]]; then
  cpm_app="path:${cpm_repo}#compile-and-build-control-plane-model"
fi

mkdir -p "$out_root"

for example_dir in "$labs_root"/*; do
  [[ -d "$example_dir" ]] || continue

  name="$(basename "$example_dir")"
  intent="$example_dir/intent.nix"
  inventory="$example_dir/inventory.nix"

  [[ -f "$intent" ]] || { echo "[!] SKIP ${name}: missing intent.nix" >&2; continue; }
  [[ -f "$inventory" ]] || { echo "[!] SKIP ${name}: missing inventory.nix" >&2; continue; }

  echo "[*] ${name}"

  (
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clabgen.${name}.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT

    cpm_json="$tmp_dir/output-control-plane-model.json"
    topo_out="$out_root/$name/fabric.clab.yml"
    bridges_out="$out_root/$name/vm-bridges-generated.nix"

    mkdir -p "$out_root/$name"

    nix run "$cpm_app" -- "$intent" "$inventory" "$cpm_json" >/dev/null

    nix run "path:${repo_root}#generate-clab-config" -- "$cpm_json" "$topo_out" "$bridges_out" >/dev/null

    echo "    - $topo_out"
    echo "    - $bridges_out"
  )
done
