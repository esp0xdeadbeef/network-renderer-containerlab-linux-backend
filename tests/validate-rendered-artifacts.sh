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

scratch_dir="${CLAB_VALIDATE_SCRATCH_DIR:-${repo_root}/clab-fabric}"

created_clab_fabric=0
if [[ ! -d "${scratch_dir}" ]]; then
  mkdir -p "${scratch_dir}"
  created_clab_fabric=1
fi
cleanup_clab_fabric() {
  if [[ "${created_clab_fabric}" -eq 1 ]]; then
    rmdir "${scratch_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_clab_fabric EXIT

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
if re.search(r"(?m)^\s*-\s+type:\s+macvlan\s*$", raw):
    raise SystemExit(f"validator: host attachment links must use bridge-kind endpoints, not macvlan: {p}")

if links_with_endpoints < 1:
    raise SystemExit(f"validator: YAML contains no renderable links: {p}")

link_blocks = re.findall(
    r"(?ms)^\s*-\s+endpoints:\s*$"
    r"(.*?)(?=^\s*-\s+endpoints:|\Z)",
    raw,
)
for index, block in enumerate(link_blocks, start=1):
    endpoints = re.findall(r'(?m)^\s*-\s+"?([^"\s][^"\n]*)"?\s*$', block)
    endpoints = [ep.strip() for ep in endpoints if ":" in ep]
    if len(endpoints) != 2:
        raise SystemExit(
            f"validator: Containerlab link {index} must have exactly 2 endpoints, got {len(endpoints)}: {endpoints}"
        )

bridge_nodes = set()
node_blocks = re.findall(
    r"(?ms)^    ([A-Za-z0-9_.-]+):\n(.*?)(?=^    [A-Za-z0-9_.-]+:|\n  links:|\Z)",
    raw,
)
for name, block in node_blocks:
    if re.search(r"(?m)^      kind:\s+bridge\s*$", block):
        bridge_nodes.add(name)

bridge_ifaces = {}
for endpoint in re.findall(r'(?m)^\s*-\s+"?([^"\s][^"\n]*)"?\s*$', raw):
    endpoint = endpoint.strip()
    if ":" not in endpoint:
        continue
    node, iface = endpoint.split(":", 1)
    if node not in bridge_nodes:
        continue
    if iface in bridge_ifaces:
        raise SystemExit(
            "validator: Containerlab bridge-kind root endpoint "
            f"{iface!r} is reused by {bridge_ifaces[iface]!r} and {node!r}"
        )
    bridge_ifaces[iface] = node

endpoint_lines = re.findall(r'(?m)^\s*-\s+"?[^"\s:]+:[^"\s:]+"?\s*$', raw)
if len(endpoint_lines) < (links_with_endpoints * 2):
    raise SystemExit(f"validator: YAML links do not define two endpoint entries per link: {p}")

host_endpoints = re.findall(r'(?m)^\s*-\s+"?host:([^"\s:]+)"?\s*$', raw)
duplicates = sorted({ep for ep in host_endpoints if host_endpoints.count(ep) > 1})
if duplicates:
    raise SystemExit(
        f"validator: host endpoints must be unique for Containerlab: {', '.join(duplicates)}"
    )

bridge_labels = sorted(set(re.findall(r"(?m)^\s*clab\.link\.bridge:\s+(\S+)\s*$", raw)))
too_long = [bridge for bridge in bridge_labels if len(bridge) > 15]
if too_long:
    raise SystemExit(
        "validator: rendered Linux bridge names exceed IFNAMSIZ: "
        + ", ".join(too_long)
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
      expectedVlanIfNames =
        lib.filter builtins.isString (
          lib.mapAttrsToList (
            _name: network:
            if
              builtins.isAttrs network
              && (network.mode or "") == "vlan"
              && builtins.isString (network.parent or null)
              && builtins.isInt (network.vlan or null)
            then
              "${network.parent}.${toString network.vlan}"
            else
              null
          ) bridgeNetworks
        );
      missingVlanNetdevs = builtins.filter (
        ifName: !(builtins.elem "11-${ifName}" netdevNames)
      ) expectedVlanIfNames;
    in
    {
      bridges = bridges;
      bridgeCount = builtins.length bridges;
      uniqueBridgeCount = builtins.length (lib.unique bridges);
      nonStringCount = builtins.length (builtins.filter (v: !builtins.isString v) bridges);
      bridgeNetworkCount = builtins.length (builtins.attrNames bridgeNetworks);
      netdevCount = builtins.length netdevNames;
      networkCount = builtins.length networkNames;
      missingVlanNetdevs = missingVlanNetdevs;
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
too_long = [name for name in result.get("bridges", []) if len(name) > 15]
if too_long:
    raise SystemExit(
        "validator: generated VM bridge names exceed IFNAMSIZ: "
        + ", ".join(too_long)
    )
if not result["namesMatch"]:
    raise SystemExit("validator: vm.nix bridge names do not match generated bridges")
if result["missingVlanNetdevs"]:
    raise SystemExit(
        "validator: vm.nix does not create VLAN netdevs for host bridge networks: "
        + ", ".join(result["missingVlanNetdevs"])
    )
PY
