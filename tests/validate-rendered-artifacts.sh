#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tests/validate-rendered-artifacts.sh <fabric.clab.yml> <vm-bridges-generated.nix>
EOF
}

topology_file="${1:-}"
bridges_file="${2:-}"

if [[ -z "${topology_file}" || -z "${bridges_file}" ]]; then
  usage
  exit 1
fi

[[ -s "${topology_file}" ]] || { echo "validator: missing or empty topology YAML: ${topology_file}" >&2; exit 1; }
[[ -s "${bridges_file}" ]] || { echo "validator: missing or empty bridges nix: ${bridges_file}" >&2; exit 1; }

topology_file="$(realpath "${topology_file}")"
bridges_file="$(realpath "${bridges_file}")"

python3 - "${topology_file}" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
raw = p.read_text()

if not re.search(r"(?m)^name:\s*\S", raw):
    raise SystemExit(f"validator: YAML missing non-empty top-level name: {p}")
if not re.search(r"(?m)^topology:\s*$", raw):
    raise SystemExit(f"validator: YAML missing top-level topology section: {p}")
if not re.search(r"(?m)^\s*nodes:\s*$", raw):
    raise SystemExit(f"validator: YAML missing topology.nodes section: {p}")
if not re.search(r"(?m)^\s*links:\s*$", raw):
    raise SystemExit(f"validator: YAML missing topology.links section: {p}")

links_with_endpoints = len(re.findall(r"(?m)^\s*-\s+endpoints:\s*$", raw))
if links_with_endpoints < 1:
    raise SystemExit(f"validator: YAML contains no links with endpoints: {p}")

endpoint_lines = re.findall(r'(?m)^\s*-\s+"?[^"\s:]+:[^"\s:]+"?\s*$', raw)
if len(endpoint_lines) < (links_with_endpoints * 2):
    raise SystemExit(f"validator: YAML links do not define two endpoint entries per link: {p}")

host_endpoints = re.findall(r'(?m)^\s*-\s+"?host:([^"\s:]+)"?\s*$', raw)
duplicates = sorted({ep for ep in host_endpoints if host_endpoints.count(ep) > 1})
if duplicates:
    raise SystemExit(
        f"validator: host endpoints must be unique for Containerlab: {', '.join(duplicates)}"
    )
PY

validation_json="$(
  REPO_ROOT="${repo_root}" \
  BRIDGES_FILE="${bridges_file}" \
  CLAB_VM_BRIDGES_FILE="${bridges_file}" \
  VM_NIX_FILE="${repo_root}/vm.nix" \
  nix eval --impure --json --expr '
    let
      repoRoot = builtins.getEnv "REPO_ROOT";
      bridgesPath = builtins.toPath (builtins.getEnv "BRIDGES_FILE");
      vmNixPath = builtins.toPath (builtins.getEnv "VM_NIX_FILE");
      flake = builtins.getFlake ("path:" + repoRoot);
      pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
      lib = pkgs.lib;
      generated = import bridgesPath { inherit lib; };
      bridges = generated.bridges or (throw "generated bridges file must export attribute bridges");
      bridgeNetworks = generated.bridgeNetworks or {};
      vmModule = import vmNixPath {
        inherit lib pkgs;
        config = { };
      };
      netdevNames = builtins.attrNames (vmModule.systemd.network.netdevs or { });
      networkNames = builtins.attrNames (vmModule.systemd.network.networks or { });
      missingNetdevBridges = builtins.filter (bridge: !(builtins.elem bridge netdevNames)) bridges;
      missingNetworkBridges = builtins.filter (bridge: !(builtins.elem bridge networkNames)) bridges;
    in
    {
      bridgeCount = builtins.length bridges;
      uniqueBridgeCount = builtins.length (lib.unique bridges);
      nonStringCount = builtins.length (builtins.filter (v: !builtins.isString v) bridges);
      bridgeNetworkCount = builtins.length (builtins.attrNames bridgeNetworks);
      netdevCount = builtins.length netdevNames;
      networkCount = builtins.length networkNames;
      namesMatch =
        if bridgeNetworks == {} then
          (lib.sort builtins.lessThan netdevNames) == (lib.sort builtins.lessThan bridges)
          && (lib.sort builtins.lessThan networkNames) == (lib.sort builtins.lessThan bridges)
        else
          missingNetdevBridges == [] && missingNetworkBridges == [];
    }
  '
)"

VALIDATION_JSON="${validation_json}" python3 - <<'PY'
import json
import os

result = json.loads(os.environ["VALIDATION_JSON"])

if result["bridgeCount"] < 1:
    raise SystemExit("validator: expected at least one generated bridge")
if result["uniqueBridgeCount"] != result["bridgeCount"]:
    raise SystemExit("validator: generated bridges contain duplicates")
if result["nonStringCount"] != 0:
    raise SystemExit("validator: generated bridges must all be strings")
if not result["namesMatch"]:
    raise SystemExit("validator: vm.nix bridge names do not match generated bridges")
PY
