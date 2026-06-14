#!/usr/bin/env bash
# seed.sh — Seed CPM JSON test fixtures for the CLAB renderer.
#
# Usage:
#   scripts/seed.sh [--intent INTENT_PATH] [--inventory INVENTORY_PATH] [--name FIXTURE_NAME]
#
#   scripts/seed.sh --all   Seed all known examples from network-labs
#
# Default intent/inventory paths (when not --all):
#   if INTENT_PATH is set: seed exactly one fixture from that intent+inventory
#   if unset: error, must provide --all or explicit paths
#
# Output:
#   tests/fixtures/<name>/output-control-plane-model.json
#   tests/fixtures/<name>/renderer-inventory.json
#
# Idempotent: if a fixture already exists, skip (unless --force).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="${repo_root}/tests/fixtures"

usage() {
  cat >&2 <<'EOF'
usage: scripts/seed.sh [OPTIONS]

Options:
  --intent PATH       Path to intent.nix
  --inventory PATH    Path to inventory-clab.nix (or inventory-nixos.nix, etc.)
  --name NAME         Fixture directory name (default: derived from intent basename dir)
  --all               Seed all examples from network-labs
  --force             Overwrite existing fixtures
  -h, --help          Show this help

Examples:
  scripts/seed.sh --intent ./intent.nix --inventory ./inventory-clab.nix --name single-wan
  scripts/seed.sh --all
  scripts/seed.sh --all --force
EOF
}

resolve_flake_input_path() {
  local input_name="$1"
  local archive_json
  archive_json="$(mktemp)"
  trap 'rm -f "$archive_json"' RETURN

  nix flake archive --json "path:${repo_root}" >"${archive_json}"

  INPUT_NAME="${input_name}" ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      name = builtins.getEnv "INPUT_NAME";
      input = archived.inputs.${name} or null;
      p = if input == null then null else input.path or null;
    in
      if p == null then
        throw "seed.sh: missing flake input path for " + name
      else
        p
  '
}

force=false
all=false
intent_path=""
inventory_path=""
fixture_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intent) intent_path="$2"; shift 2 ;;
    --inventory) inventory_path="$2"; shift 2 ;;
    --name) fixture_name="$2"; shift 2 ;;
    --all) all=true; shift ;;
    --force) force=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "seed.sh: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# Resolve CPM path from flake inputs
cpm_path="$(resolve_flake_input_path network-control-plane-model)"
labs_path="$(resolve_flake_input_path network-labs)"

seed_one() {
  local intent="$1"
  local inventory="$2"
  local name="$3"

  local out_dir="${fixtures_dir}/${name}"
  local cpm_json="${out_dir}/output-control-plane-model.json"
  local inv_json="${out_dir}/renderer-inventory.json"

  if [[ -f "${cpm_json}" ]] && [[ -f "${inv_json}" ]] && [[ "${force}" != "true" ]]; then
    echo "seed.sh: fixture '${name}' already exists, skipping (use --force to overwrite)"
    return 0
  fi

  mkdir -p "${out_dir}"

  echo "seed.sh: building CPM for '${name}'..."
  echo "  intent:    ${intent}"
  echo "  inventory: ${inventory}"

  # Run the full pipeline: compiler -> NFM -> CPM -> emit CPM JSON
  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${cpm_path}\";
      lib = flake.lib.\"\${builtins.currentSystem}\";
      intent = import \"$(realpath "${intent}")\";
      inventory = import \"$(realpath "${inventory}")\";
      result = lib.compileAndBuild {
        input = intent;
        inherit inventory;
      };
    in
      result
  " > "${cpm_json}"

  if [[ ! -f "${cpm_json}" ]]; then
    echo "seed.sh: ERROR: CPM did not produce ${cpm_json}" >&2
    return 1
  fi

  # Emit renderer-inventory JSON (extract from CPM output or generate from inventory)
  # The renderer-inventory.json contains the renderer-scoped realization data.
  # For CLAB, we extract the inventory facts from the CPM output that are relevant
  # to the containerlab renderer, or use a companion inventory file if available.
  #
  # Strategy: Use the inventory path to determine renderer inventory.
  # The CPM's compile-and-build emits renderer-inventory as a side artifact, or
  # we construct one from the source inventory path.
  local inv_nix_dir="$(dirname "${inventory}")"
  local clab_inv_candidate="${inv_nix_dir}/inventory-clab.nix"

  if [[ -f "${CLAB_RENDERER_INVENTORY:-}" ]]; then
    # User-supplied renderer inventory JSON
    cp "${CLAB_RENDERER_INVENTORY}" "${inv_json}"
  elif [[ -f "${inv_nix_dir}/renderer-inventory.json" ]]; then
    cp "${inv_nix_dir}/renderer-inventory.json" "${inv_json}"
  else
    # Derive renderer inventory from the source: use CPM's renderer-contract extraction
    # or construct a minimal one from the inventory path
    echo "seed.sh: constructing renderer-inventory from source..."
    python3 - "$inventory" "$inv_json" <<'PY'
import sys, json, os
inv_path = sys.argv[1]
out_path = sys.argv[2]
# Read the inventory Nix file and extract renderer-relevant data
# For now, emit a minimal inventory JSON referencing the source
# Full inventory construction is renderer-specific and belongs in a future enhancement
inv = {
    "sourceInventoryPath": os.path.abspath(inv_path),
    "renderer": "containerlab-linux-backend",
}
with open(out_path, 'w') as f:
    json.dump(inv, f, indent=2)
PY
  fi

  echo "seed.sh: fixture '${name}' seeded:"
  echo "  ${cpm_json}"
  echo "  ${inv_json}"
}

if [[ "${all}" == "true" ]]; then
  examples_root="${labs_path}/examples"
  if [[ ! -d "${examples_root}" ]]; then
    echo "seed.sh: ERROR: examples root not found: ${examples_root}" >&2
    exit 1
  fi

  count=0
  for example_dir in "${examples_root}"/*; do
    [[ -d "${example_dir}" ]] || continue
    name="$(basename "${example_dir}")"
    intent="${example_dir}/intent.nix"
    inventory="${example_dir}/inventory-clab.nix"

    if [[ ! -f "${intent}" ]]; then
      echo "seed.sh: SKIP ${name}: missing intent.nix"
      continue
    fi
    if [[ ! -f "${inventory}" ]]; then
      echo "seed.sh: SKIP ${name}: missing inventory-clab.nix"
      continue
    fi

    seed_one "${intent}" "${inventory}" "${name}"
    count=$((count + 1))
  done
  echo "seed.sh: seeded ${count} fixtures"
elif [[ -n "${intent_path}" ]] && [[ -n "${inventory_path}" ]]; then
  if [[ -z "${fixture_name}" ]]; then
    fixture_name="$(basename "$(dirname "${intent_path}")")"
  fi
  seed_one "${intent_path}" "${inventory_path}" "${fixture_name}"
else
  echo "seed.sh: ERROR: must provide --all or both --intent and --inventory" >&2
  usage
  exit 2
fi
