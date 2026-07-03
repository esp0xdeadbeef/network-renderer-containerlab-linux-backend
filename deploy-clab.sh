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
fail() {
  local context="${CLAB_FAILURE_CONTEXT:-direct-host-clab}"
  local locked_source="${CLAB_LOCKED_SOURCE_IDENTITY:-${repo_root:-unknown}}"
  printf '[deploy-clab] error: %s [directHostContext=%s lockedSource=%s]\n' "$*" "${context}" "${locked_source}" >&2
  exit 1
}

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
deploy_provenance_file="${work_dir}/clab-renderer-deploy-provenance.json"

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

lab_emulation_match = re.search(
    r"(?ms)^\s*labEmulationArtifacts\s*=\s*builtins\.fromJSON\s*''\n(.*?)^\s*'';",
    raw,
)
lab_emulation_artifacts = (
    json.loads(lab_emulation_match.group(1)) if lab_emulation_match else []
)
if not isinstance(lab_emulation_artifacts, list):
    raise SystemExit("rendered labEmulationArtifacts must be a list")

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
            "labEmulationArtifacts": lab_emulation_artifacts,
            "natBridgeNames": sorted(set(nat_bridge_names)),
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY
}

write_deploy_provenance() {
  log "writing renderer deploy provenance ${deploy_provenance_file}"
  REPO_ROOT="${repo_root}" \
  CPM_JSON="${cpm_json}" \
  RENDERER_INVENTORY_JSON="${renderer_inventory_json}" \
  WORK_DIR="${work_dir}" \
  TOPOLOGY_FILE="${topology_file}" \
  BRIDGES_FILE="${bridges_file}" \
  BRIDGE_PLAN_FILE="${bridge_plan_file}" \
  TOOLING_CACHE_EVIDENCE_FILE="${tooling_cache_evidence_file}" \
  DEPLOY_PROVENANCE_FILE="${deploy_provenance_file}" \
    "${python_bin}" - <<'PY'
import json
import os
from pathlib import Path

from clabgen.provenance_fields import renderer_lock_summary, renderer_source_identity

repo_root = Path(os.environ["REPO_ROOT"])
payload = {
    "schema": "clab-renderer-deploy-provenance.v1",
    "renderer": renderer_source_identity(repo_root),
    "locks": {
        "renderer": renderer_lock_summary(repo_root),
    },
    "inputs": {
        "controlPlaneModel": os.environ["CPM_JSON"],
        "rendererInventory": os.environ["RENDERER_INVENTORY_JSON"],
    },
    "artifacts": {
        "topology": os.environ["TOPOLOGY_FILE"],
        "bridges": os.environ["BRIDGES_FILE"],
        "bridgePlan": os.environ["BRIDGE_PLAN_FILE"],
        "toolingCacheEvidence": os.environ["TOOLING_CACHE_EVIDENCE_FILE"],
    },
    "workDir": os.environ["WORK_DIR"],
}
Path(os.environ["DEPLOY_PROVENANCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
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

sanitize_label() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

bridge_for_live_vlan() {
  local vlan="$1"
  jq -r --argjson vlan "${vlan}" '
    .bridgeNetworks
    | to_entries[]
    | select((.value.mode // "") == "vlan" and (.value.vlan | tonumber?) == $vlan)
    | (.value.bridge // .key)
  ' "${bridge_plan_file}" | head -n 1
}

start_fake_provider_dhcp4() {
  local name="$1"
  local bridge="$2"
  local address="$3"
  local router="$4"
  local range_start="$5"
  local range_end="$6"
  local lease_time="$7"
  local dns_servers="$8"
  local label pid_file lease_file log_file

  validate_ifname "${bridge}"
  label="$(sanitize_label "${name}-${bridge}")"
  [[ -n "${label}" ]] || fail "fake-provider lab emulation has empty sanitized label"
  pid_file="${work_dir}/lab-emulation-${label}.dnsmasq.pid"
  lease_file="${work_dir}/lab-emulation-${label}.leases"
  log_file="${work_dir}/lab-emulation-${label}.dnsmasq.log"

  log "configuring fake-provider DHCPv4 ${name} on ${bridge} (${address})"
  ip addr replace "${address}" dev "${bridge}"
  ip link set "${bridge}" up

  if [[ -s "${pid_file}" ]]; then
    kill "$(cat "${pid_file}")" >/dev/null 2>&1 || true
    rm -f "${pid_file}"
  fi

  local dns_args=()
  if [[ -n "${dns_servers}" ]]; then
    dns_args=(--dhcp-option=option:dns-server,"${dns_servers}")
  fi

  dnsmasq \
    --conf-file=/dev/null \
    --no-hosts \
    --no-resolv \
    --port=0 \
    --bind-interfaces \
    --interface="${bridge}" \
    --dhcp-authoritative \
    --dhcp-range="${range_start},${range_end},${lease_time}" \
    --dhcp-option=option:router,"${router}" \
    "${dns_args[@]}" \
    --pid-file="${pid_file}" \
    --dhcp-leasefile="${lease_file}" \
    --log-facility="${log_file}"
}

enable_fake_provider_nat44() {
  local name="$1"
  local source_prefix="$2"
  local default_oif chain

  default_oif="$(ip -o -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "${default_oif}" ]] || fail "fake-provider ${name} requested NAT44 but host has no IPv4 default route"
  validate_ifname "${default_oif}"
  chain="postrouting_$(sanitize_label "${name}")"
  [[ -n "${chain}" ]] || fail "fake-provider ${name} produced empty NAT chain name"

  log "configuring fake-provider NAT44 ${name} source=${source_prefix} oif=${default_oif}"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  nft add table ip clab_lab_emulation >/dev/null 2>&1 || true
  nft "add chain ip clab_lab_emulation ${chain} { type nat hook postrouting priority 102; policy accept; }" >/dev/null 2>&1 || true
  nft flush chain ip clab_lab_emulation "${chain}" >/dev/null 2>&1 || true
  nft add rule ip clab_lab_emulation "${chain}" oifname "${default_oif}" ip saddr "${source_prefix}" masquerade
}

materialize_lab_emulation() {
  local count artifact mode scope name live_vlan bridge dhcp4_type address router range_start range_end lease_time dns_servers nat_enabled source_prefix

  count="$(jq -r '.labEmulationArtifacts | length' "${bridge_plan_file}")"
  ((count > 0)) || return 0

  while read -r artifact; do
    mode="$(jq -r '.providerEmulationMode // ""' <<<"${artifact}")"
    scope="$(jq -r '.scope // ""' <<<"${artifact}")"
    name="$(jq -r '.name // .providerEmulationMode // "unnamed"' <<<"${artifact}")"

    case "${mode}" in
      fake-provider)
        ;;
      pppoe-like)
        log "lab-emulation ${name}: pppoe-like has no host-side DHCP materialization"
        continue
        ;;
      *)
        fail "unsupported lab-emulation artifact mode for deploy: ${mode:-<missing>}"
        ;;
    esac

    [[ "${scope}" == "harness" ]] || fail "fake-provider ${name} must be harness scoped"
    live_vlan="$(jq -r '.liveUpstreamReachability.vlan // empty' <<<"${artifact}")"
    [[ "${live_vlan}" =~ ^[0-9]+$ ]] || fail "fake-provider ${name} requires liveUpstreamReachability.vlan for host materialization"

    bridge="$(bridge_for_live_vlan "${live_vlan}")"
    [[ -n "${bridge}" ]] || fail "fake-provider ${name} live upstream VLAN ${live_vlan} has no matching rendered vlan bridge"

    dhcp4_type="$(jq -r '(.dhcp4 // null) | type' <<<"${artifact}")"
    [[ "${dhcp4_type}" == "object" ]] || fail "fake-provider ${name} live upstream VLAN ${live_vlan} requires explicit dhcp4 object"

    address="$(jq -r '.dhcp4.address // empty' <<<"${artifact}")"
    router="$(jq -r '.dhcp4.router // empty' <<<"${artifact}")"
    range_start="$(jq -r '.dhcp4.rangeStart // empty' <<<"${artifact}")"
    range_end="$(jq -r '.dhcp4.rangeEnd // empty' <<<"${artifact}")"
    lease_time="$(jq -r '.dhcp4.leaseTime // empty' <<<"${artifact}")"
    dns_servers="$(jq -r '(.dhcp4.dnsServers // []) | join(",")' <<<"${artifact}")"
    [[ -n "${address}" && -n "${router}" && -n "${range_start}" && -n "${range_end}" && -n "${lease_time}" ]] \
      || fail "fake-provider ${name} dhcp4 requires address, router, rangeStart, rangeEnd, and leaseTime"

    start_fake_provider_dhcp4 "${name}" "${bridge}" "${address}" "${router}" "${range_start}" "${range_end}" "${lease_time}" "${dns_servers}"

    nat_enabled="$(jq -r '(.nat44.enabled // false) | tostring' <<<"${artifact}")"
    if [[ "${nat_enabled}" == "true" ]]; then
      source_prefix="$(jq -r '.nat44.sourcePrefix // .dhcp4.sourcePrefix // empty' <<<"${artifact}")"
      [[ -n "${source_prefix}" ]] || fail "fake-provider ${name} NAT44 requires nat44.sourcePrefix or dhcp4.sourcePrefix"
      enable_fake_provider_nat44 "${name}" "${source_prefix}"
    fi
  done < <(jq -c '.labEmulationArtifacts[]' "${bridge_plan_file}")
}

wait_for_docker() {
  # FS-960-HDS-010-SDS-016-SMS-050: privileged Docker inspection with distinguishable
  # failure diagnostics (permission denial, daemon absence, sudo misconfiguration).
  local wait_seconds="${CLAB_DOCKER_WAIT_SECONDS:-120}"
  local deadline=$((SECONDS + wait_seconds))

  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker >/dev/null 2>&1 || true
  fi

  local docker_cmd=(docker)
  local euid="${CLAB_TEST_EUID:-${EUID:-$(id -u 2>/dev/null || echo 0)}}"
  if [[ "${euid}" -ne 0 ]]; then
    if [[ "${CLAB_TEST_DISABLE_SUDO:-0}" != "1" ]] && command -v sudo >/dev/null 2>&1; then
      docker_cmd=(sudo -n docker)
    fi
  fi

  local last_stderr=""
  while ((SECONDS < deadline)); do
    if last_stderr="$("${docker_cmd[@]}" info 2>&1 >/dev/null)"; then
      return 0
    fi
    sleep 1
  done

  # FS-960-HDS-010-SDS-016-SMS-050: distinguishable failure diagnostics.
  if [[ "${last_stderr}" == *"permission denied"* ]] || [[ "${last_stderr}" == *"Permission denied"* ]]; then
    fail "docker permission denied — user not authorized to access Docker daemon (verify docker group membership or sudo NOPASSWD configuration)"
  elif [[ "${last_stderr}" == *"password is required"* ]]; then
    fail "docker privilege check failed — sudo -n requires NOPASSWD or an active sudo ticket"
  else
    fail "docker did not become ready after ${wait_seconds}s (daemon may not be running or unreachable)"
  fi
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

retry_wan_dhcp_clients() {
  local name="$1"
  local containers=()
  local container

  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E "^clab-${name}-" | sort || true)
  ((${#containers[@]} > 0)) || return 0

  for container in "${containers[@]}"; do
    docker exec "${container}" sh -eu -c '
      for path in /sys/class/net/u*; do
        test -e "$path" || continue
        iface="${path##*/}"
        case "$iface" in
          u*[!0-9]*)
            continue
            ;;
        esac
        ip link set "$iface" up
        if ip -4 addr show dev "$iface" | grep -q " inet "; then
          continue
        fi
        test -x /sbin/udhcpc || continue
        timeout 12 udhcpc -q -n -i "$iface" -s /bin/true >/dev/null 2>&1 || true
      done
    '
  done
}

verify_fabric_containers() {
  local name="$1"
  local containers=()
  local container

  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E "^clab-${name}-" | sort || true)
  if ((${#containers[@]} == 0)); then
    if grep -Eq '^[[:space:]]+nodes:[[:space:]]*\{\}[[:space:]]*$' "${topology_file}"; then
      log "empty Containerlab topology for ${name}; no containers expected"
      return 0
    fi
    fail "no running fabric containers found for lab ${name}"
  fi

  for container in "${containers[@]}"; do
    docker exec "${container}" sh -ec '
      ip -o link show up | awk -F": " "$2 != \"lo\" && $2 !~ /^lo@/ { found = 1 } END { exit found ? 0 : 1 }"
    ' || fail "container ${container} has no non-loopback interface up"
    health="$(
      docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}"
    )" || fail "container ${container} health status could not be inspected"
    case "${health}" in
      healthy|none)
        ;;
      *)
        fail "container ${container} health check is ${health}"
        ;;
    esac
  done
  log "verified ${#containers[@]} fabric containers"
}

render_artifacts
write_bridge_plan
write_deploy_provenance

name="$(lab_name)"
[[ -n "${name}" ]] || fail "rendered topology is missing a top-level lab name"

if ((dry_run)); then
  log "dry-run: rendered topology=${topology_file}"
  log "dry-run: rendered bridges=${bridges_file}"
  log "dry-run: bridge plan=${bridge_plan_file}"
  log "dry-run: renderer deploy provenance=${deploy_provenance_file}"
  log "dry-run: Docker tooling image cache evidence=${tooling_cache_evidence_file}"
  log "dry-run: would ensure Docker tooling image cache, cleanup ${name}, materialize bridges, deploy, rematerialize bridges, materialize lab emulation, retry WAN DHCP, and verify containers"
  exit 0
fi

wait_for_docker
ensure_tooling_image_cache
cleanup_stale_lab "${name}"
materialize_bridges
deploy_lab
materialize_bridges
materialize_lab_emulation
retry_wan_dhcp_clients "${name}"
verify_fabric_containers "${name}"
