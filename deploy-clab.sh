#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  deploy-clab [--work-dir DIR] [--dry-run] <control-plane-model.json> <renderer-inventory.json>

Renders Containerlab artifacts from explicit CPM and renderer inventory inputs,
then prepares host bridges, clears stale lab state, deploys Containerlab, and
verifies rendered fabric containers have non-loopback interfaces.

The renderer is downstream of CPM. Build CPM before invoking this command.
EOF
}

log() { printf '[deploy-clab] %s\n' "$*"; }
fail() { printf '[deploy-clab] error: %s\n' "$*" >&2; exit 1; }

repo_root="${CLAB_RENDERER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
python_bin="${CLABGEN_PYTHON:-python3}"
work_dir="${CLAB_DEPLOY_WORK_DIR:-$(pwd)}"
dry_run=0

while (($# > 0)); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --work-dir)
      (($# >= 2)) || fail "--work-dir requires a directory"
      work_dir="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

(($# == 2)) || { usage; exit 2; }

cpm_json="$1"
renderer_inventory_json="$2"

[[ "${cpm_json}" != *.nix ]] || fail "deploy-clab consumes prebuilt CPM JSON, not intent/inventory Nix"
[[ -s "${cpm_json}" ]] || fail "missing or empty CPM JSON: ${cpm_json}"
[[ -s "${renderer_inventory_json}" ]] || fail "missing or empty renderer inventory JSON: ${renderer_inventory_json}"

mkdir -p "${work_dir}"
topology_file="${work_dir}/fabric.clab.yml"
bridges_file="${work_dir}/vm-bridges-generated.nix"
bridge_plan_file="${work_dir}/clab-bridge-plan.json"
tooling_cache_evidence_file="${work_dir}/clab-frr-tooling-cache-evidence.json"

render_artifacts() {
  log "rendering ${topology_file} and ${bridges_file}"
  CLABGEN_RENDERER_INVENTORY_JSON="${renderer_inventory_json}" \
    "${python_bin}" "${repo_root}/generate-clab-config.py" \
      "${cpm_json}" \
      "${topology_file}" \
      "${bridges_file}"
}

write_bridge_plan() {
  log "evaluating rendered bridge artifact"
  "${python_bin}" - "${bridges_file}" "${bridge_plan_file}" <<'PY'
import json
import re
import sys
from pathlib import Path

bridges_path = Path(sys.argv[1])
plan_path = Path(sys.argv[2])
raw = bridges_path.read_text()

bridges_match = re.search(r"(?ms)^\s*bridges\s*=\s*\[\n(.*?)^\s*\];", raw)
if not bridges_match:
    raise SystemExit(f"rendered bridge artifact lacks bridges list: {bridges_path}")
bridges = re.findall(r'"([^"]+)"', bridges_match.group(1))

networks_match = re.search(
    r"(?ms)^\s*bridgeNetworks\s*=\s*builtins\.fromJSON\s*''\n(.*?)^\s*'';",
    raw,
)
bridge_networks = json.loads(networks_match.group(1)) if networks_match else {}
if not isinstance(bridge_networks, dict):
    raise SystemExit("rendered bridgeNetworks must be an object")

bridge_names = set(bridges)
nat_bridge_names = []
for key, value in bridge_networks.items():
    if not isinstance(value, dict):
        continue
    bridge = value.get("bridge") if isinstance(value.get("bridge"), str) else key
    bridge_names.add(bridge)
    if value.get("mode") == "nat":
        nat_bridge_names.append(bridge)

plan_path.write_text(
    json.dumps(
        {
            "bridgeNames": sorted(bridge_names),
            "bridgeNetworks": bridge_networks,
            "natBridgeNames": sorted(set(nat_bridge_names)),
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY
}

lab_name() {
  awk '$1 == "name:" && $2 != "" { print $2; exit }' "${topology_file}"
}

validate_ifname() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "invalid interface name from rendered artifact: ${name}"
  ((${#name} <= 15)) || fail "interface name exceeds IFNAMSIZ: ${name}"
}

ensure_bridge() {
  local bridge="$1"
  validate_ifname "${bridge}"
  if ! ip link show "${bridge}" >/dev/null 2>&1; then
    log "creating bridge ${bridge}"
    ip link add name "${bridge}" type bridge
  fi
  ip link set "${bridge}" up
}

materialize_bridges() {
  local bridge network mode parent vlan vlan_if addr4

  while read -r bridge; do
    [[ -n "${bridge}" ]] || continue
    ensure_bridge "${bridge}"
  done < <(jq -r '.bridgeNames[]' "${bridge_plan_file}")

  while read -r network; do
    bridge="$(jq -r '.value.bridge // .key' <<<"${network}")"
    mode="$(jq -r '.value.mode // ""' <<<"${network}")"
    ensure_bridge "${bridge}"

    case "${mode}" in
      vlan)
        parent="$(jq -r '.value.parent // ""' <<<"${network}")"
        vlan="$(jq -r '.value.vlan // empty' <<<"${network}")"
        [[ -n "${parent}" && -n "${vlan}" ]] || fail "vlan bridge ${bridge} is missing parent or vlan"
        validate_ifname "${parent}"
        vlan_if="${parent}.${vlan}"
        validate_ifname "${vlan_if}"
        ip link show "${parent}" >/dev/null 2>&1 || fail "missing parent interface for ${bridge}: ${parent}"
        if ! ip link show "${vlan_if}" >/dev/null 2>&1; then
          log "creating vlan ${vlan_if} for bridge ${bridge}"
          ip link add link "${parent}" name "${vlan_if}" type vlan id "${vlan}"
        fi
        ip link set "${parent}" up
        ip link set "${vlan_if}" master "${bridge}"
        ip link set "${vlan_if}" up
        ;;
      nat)
        addr4="$(jq -r '.value.ipv4.address // ""' <<<"${network}")"
        if [[ -n "${addr4}" ]]; then
          log "assigning NAT bridge address ${addr4} to ${bridge}"
          ip addr replace "${addr4}" dev "${bridge}"
        fi
        ;;
      ""|bridge)
        ;;
      *)
        fail "unsupported rendered bridge network mode for ${bridge}: ${mode}"
        ;;
    esac
  done < <(jq -c '.bridgeNetworks | to_entries[]' "${bridge_plan_file}")
}

wait_for_docker() {
  local wait_seconds="${CLAB_DOCKER_WAIT_SECONDS:-120}"
  local deadline=$((SECONDS + wait_seconds))

  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker >/dev/null 2>&1 || true
  fi

  while ((SECONDS < deadline)); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done

  fail "docker did not become ready after ${wait_seconds}s"
}

ensure_tooling_image_cache() {
  if [[ -z "${CLAB_FRR_TOOLING_CACHE_DIR:-}" ]]; then
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
      export CLAB_FRR_TOOLING_CACHE_DIR="${XDG_CACHE_HOME}/network-renderer-containerlab-linux-backend/docker"
    elif [[ -n "${HOME:-}" ]]; then
      export CLAB_FRR_TOOLING_CACHE_DIR="${HOME}/.cache/network-renderer-containerlab-linux-backend/docker"
    else
      export CLAB_FRR_TOOLING_CACHE_DIR="/tmp/network-renderer-containerlab-linux-backend/docker"
    fi
  fi
  CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON="${tooling_cache_evidence_file}" \
    "${repo_root}/docker-clab-frr-plus-tooling/build.sh"
  [[ -s "${tooling_cache_evidence_file}" ]] || fail "missing Docker tooling image cache evidence: ${tooling_cache_evidence_file}"
  log "Docker tooling image cache evidence=${tooling_cache_evidence_file}"
}

cleanup_stale_lab() {
  local name="$1"
  log "clearing stale Containerlab state for ${name}"
  containerlab destroy -t "${topology_file}" --cleanup --yes >/dev/null 2>&1 || true
  docker ps -aq --filter "name=^clab-${name}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

deploy_lab() {
  log "deploying Containerlab topology ${topology_file}"
  containerlab deploy -t "${topology_file}" --reconfigure
  containerlab inspect -t "${topology_file}" >/dev/null
}

verify_fabric_containers() {
  local name="$1"
  local containers=()
  local container

  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E "^clab-${name}-" | sort || true)
  ((${#containers[@]} > 0)) || fail "no running fabric containers found for lab ${name}"

  for container in "${containers[@]}"; do
    docker exec "${container}" sh -ec '
      ip -o link show up | awk -F": " "$2 != \"lo\" && $2 !~ /^lo@/ { found = 1 } END { exit found ? 0 : 1 }"
    ' || fail "container ${container} has no non-loopback interface up"
  done
  log "verified ${#containers[@]} fabric containers"
}

render_artifacts
write_bridge_plan

name="$(lab_name)"
[[ -n "${name}" ]] || fail "rendered topology is missing a top-level lab name"

if ((dry_run)); then
  log "dry-run: rendered topology=${topology_file}"
  log "dry-run: rendered bridges=${bridges_file}"
  log "dry-run: bridge plan=${bridge_plan_file}"
  log "dry-run: Docker tooling image cache evidence=${tooling_cache_evidence_file}"
  log "dry-run: would ensure Docker tooling image cache, cleanup ${name}, materialize bridges, deploy, and verify containers"
  exit 0
fi

wait_for_docker
ensure_tooling_image_cache
cleanup_stale_lab "${name}"
materialize_bridges
deploy_lab
verify_fabric_containers "${name}"
