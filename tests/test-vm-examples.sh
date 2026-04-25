#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vm_ssh_port="${CLAB_VM_SSH_PORT:-2222}"
vm_state_dir="${CLAB_VM_STATE_DIR:-}"
ephemeral_vm_state_dir=""
host_cache_root="${CLAB_VM_HOST_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend}"
host_image_cache_tar="${host_cache_root}/clab-frr-plus-tooling-latest.tar"
host_image_cache_id="${host_cache_root}/clab-frr-plus-tooling-latest.image-id"
host_image_cache_lock="${host_cache_root}/clab-frr-plus-tooling.lock"
vm_image_cache_tar="/var/tmp/clab-frr-plus-tooling-latest.tar"
vm_image_cache_id="/var/tmp/clab-frr-plus-tooling-latest.image-id"
tooling_image="clab-frr-plus-tooling:latest"
work_root="${CLAB_VM_WORK_ROOT:-${vm_state_dir:-${host_cache_root}/vm-example-work}}"
host_tooling_cache_available=1

if [[ -z "${vm_state_dir}" ]]; then
  runtime_root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  mkdir -p "${runtime_root}/network-renderer-containerlab-linux-backend"
  ephemeral_vm_state_dir="$(mktemp -d "${runtime_root}/network-renderer-containerlab-linux-backend/vm-state.XXXXXX")"
  vm_state_dir="${ephemeral_vm_state_dir}"
  work_root="${CLAB_VM_WORK_ROOT:-${ephemeral_vm_state_dir}/work}"
fi

ssh_opts=(
  -T
  -o BatchMode=yes
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=no
  -o GlobalKnownHostsFile=/dev/null
  -o UserKnownHostsFile=/dev/null
  -o UpdateHostKeys=no
  -p "${vm_ssh_port}"
)

scp_opts=(
  -o BatchMode=yes
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=no
  -o GlobalKnownHostsFile=/dev/null
  -o UserKnownHostsFile=/dev/null
  -o UpdateHostKeys=no
  -P "${vm_ssh_port}"
)

log() {
  printf '[vm-test] %s\n' "$*"
}

ensure_host_tooling_image_cache() {
  local current_id=""
  local cached_id=""

  mkdir -p "${host_cache_root}"

  if ! docker version >/dev/null 2>&1; then
    log "host Docker daemon unavailable; skipping host-side ${tooling_image} cache export"
    host_tooling_cache_available=0
    return 0
  fi

  while ! mkdir "${host_image_cache_lock}" 2>/dev/null; do
    sleep 1
  done

  trap 'rmdir "${host_image_cache_lock}" >/dev/null 2>&1 || true' RETURN

  if ! docker image inspect "${tooling_image}" >/dev/null 2>&1; then
    log "building ${tooling_image} on host"
    ( cd "${repo_root}" && ./docker-clab-frr-plus-tooling/build.sh )
  fi

  current_id="$(docker image inspect --format '{{.Id}}' "${tooling_image}")"
  if [[ -f "${host_image_cache_id}" ]]; then
    cached_id="$(<"${host_image_cache_id}")"
  fi

  if [[ ! -f "${host_image_cache_tar}" || "${cached_id}" != "${current_id}" ]]; then
    log "exporting ${tooling_image} to host cache"
    docker save -o "${host_image_cache_tar}.tmp" "${tooling_image}"
    mv "${host_image_cache_tar}.tmp" "${host_image_cache_tar}"
    printf '%s\n' "${current_id}" > "${host_image_cache_id}"
  fi
}

ssh_vm_ready() {
  ssh "${ssh_opts[@]}" root@localhost true >/dev/null 2>&1
}

ssh_vm() {
  local attempts="${VM_SSH_ATTEMPTS:-10}"
  local delay="${VM_SSH_DELAY_SECONDS:-2}"
  local try
  local remote_cmd="$*"

  for try in $(seq 1 "$attempts"); do
    if printf '%s\n' "set -euo pipefail" "$remote_cmd" \
      | ssh "${ssh_opts[@]}" root@localhost /run/current-system/sw/bin/bash --noprofile --norc -s
    then
      return 0
    fi

    if [[ "$try" -lt "$attempts" ]]; then
      sleep "$delay"
    fi
  done

  return 1
}

ssh_vm_once() {
  local remote_cmd="$*"
  printf '%s\n' "set -euo pipefail" "$remote_cmd" \
    | ssh "${ssh_opts[@]}" root@localhost /run/current-system/sw/bin/bash --noprofile --norc -s
}

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

cleanup_vm() {
  if [[ -n "${vm_state_dir}" ]]; then
    pkill -f "${vm_state_dir}/vm.nix" >/dev/null 2>&1 || true
    pkill -f "qemu-system-x86_64 .*${vm_state_dir}/nixos.qcow2" >/dev/null 2>&1 || true
    rm -f \
      "${vm_state_dir}/fabric.clab.yml" \
      "${vm_state_dir}/vm-bridges-generated.nix" \
      "${vm_state_dir}/run-nixos-vm" \
      "${vm_state_dir}/vm-state.log" \
      >/dev/null 2>&1 || true
  else
    pkill -f '/home/deadbeef/github/network-renderer-containerlab-linux-backend/vm.nix' >/dev/null 2>&1 || true
    pkill -f 'qemu-system-x86_64 .*network-renderer-containerlab-linux-backend/nixos.qcow2' >/dev/null 2>&1 || true
  fi
  sleep 2
}

cleanup_ephemeral_state() {
  if [[ -n "${ephemeral_vm_state_dir}" ]]; then
    rm -rf "${ephemeral_vm_state_dir}" >/dev/null 2>&1 || true
  fi
}

discover_examples() {
  local labs_path="$1"

  find "${labs_path}/examples" -mindepth 2 -maxdepth 2 -type f -name 'inventory-clab.nix' -printf '%h\n' \
    | while read -r dir; do
        if [[ -f "${dir}/intent.nix" ]]; then
          basename "${dir}"
        fi
      done \
    | sort
}

wait_for_ssh() {
  local deadline=$((SECONDS + 180))

  while (( SECONDS < deadline )); do
    if ssh_vm_ready; then
      return 0
    fi
    sleep 2
  done

  return 1
}

shutdown_vm() {
  ssh_vm 'shutdown -h now' >/dev/null 2>&1 || true
  sleep 5
  cleanup_vm
}

scp_vm_file() {
  local src="$1"
  local dst="$2"
  scp "${scp_opts[@]}" "${src}" "root@localhost:${dst}" >/dev/null
}

stage_tooling_cache_into_vm() {
  local host_id
  local vm_id=""

  ensure_host_tooling_image_cache
  if [[ "${host_tooling_cache_available}" -ne 1 ]]; then
    return 0
  fi
  host_id="$(<"${host_image_cache_id}")"

  vm_id="$(ssh_vm_once "test -f '${vm_image_cache_id}' && cat '${vm_image_cache_id}'" 2>/dev/null || true)"
  if [[ "${vm_id}" == "${host_id}" ]]; then
    return 0
  fi

  log "staging ${tooling_image} cache into the VM"
  scp_vm_file "${host_image_cache_tar}" "${vm_image_cache_tar}"
  scp_vm_file "${host_image_cache_id}" "${vm_image_cache_id}"
}

stage_rendered_topology() {
  if [[ -z "${vm_state_dir}" ]]; then
    return 0
  fi

  log "staging rendered topology into the VM"
  scp_vm_file \
    "${vm_state_dir}/fabric.clab.yml" \
    "/home/deadbeef/github/network-renderer-containerlab-linux-backend/fabric.clab.yml"
}

run_in_vm_validation() {
  log "running run-in-vm.sh inside the VM"
  stage_tooling_cache_into_vm
  ssh_vm '
    set -euo pipefail
    cd /home/deadbeef/github/network-renderer-containerlab-linux-backend
    timeout 900 env \
      CLAB_TOPO_FILE=/home/deadbeef/github/network-renderer-containerlab-linux-backend/fabric.clab.yml \
      CLAB_FRR_TOOLING_CACHE_TAR='"${vm_image_cache_tar}"' \
      CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE='"${vm_image_cache_id}"' \
      ./run-in-vm.sh
  '
  log "run-in-vm.sh completed"
}

compile_example_cpm() {
  local example="$1"
  local out_json="$2"
  local labs_path="$3"
  local cpm_path="$4"

  nix run "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${labs_path}/examples/${example}/intent.nix" \
    "${labs_path}/examples/${example}/inventory-clab.nix" \
    "${out_json}" >/dev/null
}

extract_example_context() {
  local example="$1"
  local cpm_json="$2"

  python3 - <<'PY' "$example" "$cpm_json"
import json
import sys

example = sys.argv[1]
data = json.load(open(sys.argv[2]))["control_plane_model"]["data"]

def emit(key, value):
    print(f"{key}={value}")

def find_rt(logical_name):
    for enterprise, sites in data.items():
        for site, site_data in sites.items():
            for runtime_name, rt in site_data.get("runtimeTargets", {}).items():
                logical = rt.get("logicalNode") or {}
                if logical.get("name") == logical_name:
                    return enterprise, site, runtime_name, rt
    raise SystemExit(f"missing runtime target for logical node {logical_name}")

if example == "single-wan":
    _, site, rt_name, rt = find_rt("s-router-access-mgmt")
    loopback = (((rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    tenant_router4 = ((rt.get("advertisements") or {}).get("dhcp4") or [{}])[0].get("routerAddress")
    tenant_iface = ((rt.get("advertisements") or {}).get("dhcp4") or [{}])[0].get("bindInterface")
    emit("MGMT_RT", rt_name)
    emit("MGMT_SITE", site)
    emit("MGMT_LOGICAL", "s-router-access-mgmt")
    emit("MGMT_LOOP4", (loopback.get("addr4") or "").split("/")[0])
    emit("MGMT_TENANT_GW4", tenant_router4 or "")
    emit("MGMT_TENANT_IFACE", tenant_iface or "")
elif example == "dual-wan-branch-overlay":
    _, sitea_core_site, sitea_core, _ = find_rt("s-router-core-isp-a")
    _, siteb_core_site, siteb_core, _ = find_rt("b-router-core")
    _, branch_site, branch_access, branch_rt = find_rt("b-router-access-branch")
    _, sitea_mgmt_site, sitea_mgmt, sitea_rt = find_rt("s-router-access-mgmt")
    branch_loop = (((branch_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    sitea_loop = (((sitea_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    emit("SITEA_CORE_RT", sitea_core)
    emit("SITEA_CORE_SITE", sitea_core_site)
    emit("SITEA_CORE_LOGICAL", "s-router-core-isp-a")
    emit("SITEB_CORE_RT", siteb_core)
    emit("SITEB_CORE_SITE", siteb_core_site)
    emit("SITEB_CORE_LOGICAL", "b-router-core")
    emit("BRANCH_ACCESS_RT", branch_access)
    emit("BRANCH_SITE", branch_site)
    emit("BRANCH_ACCESS_LOGICAL", "b-router-access-branch")
    emit("SITEA_MGMT_RT", sitea_mgmt)
    emit("SITEA_MGMT_SITE", sitea_mgmt_site)
    emit("SITEA_MGMT_LOGICAL", "s-router-access-mgmt")
    emit("BRANCH_LOOP4", (branch_loop.get("addr4") or "").split("/")[0])
    emit("SITEA_LOOP4", (sitea_loop.get("addr4") or "").split("/")[0])
elif example == "dual-wan-branch-overlay-bgp":
    _, branch_policy_site, branch_policy, _ = find_rt("b-router-policy")
    _, branch_access_site, branch_access, branch_rt = find_rt("b-router-access-branch")
    _, sitea_mgmt_site, sitea_mgmt, sitea_rt = find_rt("s-router-access-mgmt")
    sitea_loop = (((sitea_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    branch_loop = (((branch_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    emit("BRANCH_POLICY_RT", branch_policy)
    emit("BRANCH_POLICY_SITE", branch_policy_site)
    emit("BRANCH_POLICY_LOGICAL", "b-router-policy")
    emit("BRANCH_ACCESS_RT", branch_access)
    emit("BRANCH_ACCESS_SITE", branch_access_site)
    emit("BRANCH_ACCESS_LOGICAL", "b-router-access-branch")
    emit("SITEA_MGMT_RT", sitea_mgmt)
    emit("SITEA_MGMT_SITE", sitea_mgmt_site)
    emit("SITEA_MGMT_LOGICAL", "s-router-access-mgmt")
    emit("SITEA_LOOP4", (sitea_loop.get("addr4") or "").split("/")[0])
    emit("SITEA_LOOP6", (sitea_loop.get("addr6") or "").split("/")[0])
    emit("BRANCH_LOOP4", (branch_loop.get("addr4") or "").split("/")[0])
else:
    raise SystemExit(f"no CPM extractor for {example}")
PY
}

extract_runtime_targets() {
  local cpm_json="$1"

  python3 - <<'PY' "$cpm_json"
import json
import sys

data = json.load(open(sys.argv[1]))["control_plane_model"]["data"]
targets = []
for enterprise, sites in data.items():
    for site, site_data in sites.items():
        targets.extend(site_data.get("runtimeTargets", {}).keys())

for target in sorted(targets):
    print(target)
PY
}

extract_runtime_target_suffixes() {
  local cpm_json="$1"

  python3 - <<'PY' "$cpm_json"
import json
import sys

data = json.load(open(sys.argv[1]))["control_plane_model"]["data"]
for enterprise, sites in data.items():
    for site, site_data in sites.items():
        for runtime_name, rt in sorted(site_data.get("runtimeTargets", {}).items()):
            logical = rt.get("logicalNode") or {}
            logical_name = logical.get("name")
            if logical_name:
                print(f"{site}:{logical_name}")
PY
}

load_example_context() {
  local example="$1"
  local cpm_json="$2"

  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    printf -v "$key" '%s' "$value"
    export "$key"
  done < <(extract_example_context "$example" "$cpm_json")
}

resolve_container_name() {
  local site="$1"
  local logical_name="$2"
  local pattern

  if [[ "${logical_name}" == *-core-wan ]]; then
    pattern="^clab-fabric-.*-${site}-s-router-core-.*$"
  else
    pattern="^clab-fabric-.*-${site}-${logical_name}$"
  fi

  ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1"
}

resolve_client_container_name() {
  local site="$1"
  local logical_name="$2"
  local tenant_ifname="$3"
  local pattern="^clab-fabric-.*-${site}-client-${logical_name}-${tenant_ifname}$"

  ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1"
}

check_single_wan() {
  local client
  client="$(resolve_client_container_name "${MGMT_SITE}" "${MGMT_LOGICAL}" "${MGMT_TENANT_IFACE}")"
  ssh_vm_once "
    containerlab inspect -t /home/deadbeef/github/network-renderer-containerlab-linux-backend/fabric.clab.yml >/dev/null
    docker exec '${client}' sh -lc '
    docker exec '${client}' sh -c '
      set -e
      gw=\$(ip route | awk \"/^default via / { print \\\$3; exit }\")
      ip -4 addr
      ip route
      ip route get 8.8.8.8
      test -n \"\$gw\"
      ping -c1 -W 2 \"\$gw\"
      ip route | grep -q \"^default via \"
    '
  "
}

check_runtime_target_suffixes_present() {
  local suffix
  local site
  local logical_name
  local pattern
  local deadline
  local found

  for suffix in "$@"; do
    site="${suffix%%:*}"
    logical_name="${suffix#*:}"
    if [[ "${logical_name}" == *-core-wan ]]; then
      pattern="^clab-fabric-.*-${site}-s-router-core-.*\$"
    else
      pattern="^clab-fabric-.*-${site}-${logical_name}\$"
    fi
    log "checking runtime target container pattern ${pattern}"
    deadline=$((SECONDS + 60))
    found=0

    while (( SECONDS < deadline )); do
      if ssh_vm "docker ps --format '{{.Names}}' | grep -E -q '${pattern}'"; then
        found=1
        break
      fi
      sleep 2
    done

    if [[ "${found}" -ne 1 ]]; then
      log "runtime target pattern ${pattern} did not appear; current docker ps follows"
      ssh_vm "docker ps --format '{{.Names}}'" || true
      return 1
    fi
  done
}

check_dual_wan_overlay() {
  local sitea_core
  local siteb_core
  local branch_access
  sitea_core="$(resolve_container_name "${SITEA_CORE_SITE}" "${SITEA_CORE_LOGICAL}")"
  siteb_core="$(resolve_container_name "${SITEB_CORE_SITE}" "${SITEB_CORE_LOGICAL}")"
  branch_access="$(resolve_container_name "${BRANCH_SITE}" "${BRANCH_ACCESS_LOGICAL}")"
  ssh_vm '
    set -euo pipefail
    containerlab inspect -t /home/deadbeef/github/network-renderer-containerlab-linux-backend/fabric.clab.yml >/dev/null
    docker ps --format "{{.Names}}" | grep -q "^'"${sitea_core}"'$"
    docker ps --format "{{.Names}}" | grep -q "^'"${siteb_core}"'$"
    docker exec "'"${branch_access}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
      ping -c1 '"${SITEA_LOOP4}"' >/dev/null
    "
  '
}

check_dual_wan_overlay_bgp() {
  local branch_policy
  local branch_access
  branch_policy="$(resolve_container_name "${BRANCH_POLICY_SITE}" "${BRANCH_POLICY_LOGICAL}")"
  branch_access="$(resolve_container_name "${BRANCH_ACCESS_SITE}" "${BRANCH_ACCESS_LOGICAL}")"
  ssh_vm '
    set -euo pipefail
    containerlab inspect -t /home/deadbeef/github/network-renderer-containerlab-linux-backend/fabric.clab.yml >/dev/null
    docker exec "'"${branch_access}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
      ping -c1 '"${SITEA_LOOP4}"' >/dev/null
    "
    docker exec "'"${branch_policy}"'" sh -c "
      set -e
      ip route get '"${SITEA_LOOP4}"' >/dev/null
      ip -6 route get '"${SITEA_LOOP6}"' >/dev/null
    "
  '
}

run_example() {
  local example="$1"
  local launcher_log
  local tmp_dir
  local needs_context=0
  mkdir -p "${work_root}"
  launcher_log="$(mktemp "${work_root}/clab-vm-${example}.XXXXXX.log")"
  tmp_dir="$(mktemp -d "${work_root}/clab-vm-${example}.XXXXXX")"

  case "$example" in
    single-wan|dual-wan-branch-overlay|dual-wan-branch-overlay-bgp)
      needs_context=1
      ;;
  esac

  log "compiling CPM for ${example}"
  compile_example_cpm "$example" "${tmp_dir}/cpm.json" "$labs_path" "$cpm_path"
  if [[ "${needs_context}" -eq 1 ]]; then
    load_example_context "$example" "${tmp_dir}/cpm.json"
  fi
  cleanup_vm

  log "starting VM for ${example}"
  (
    cd "$repo_root"
    CLAB_VM_STATE_DIR="${vm_state_dir}" ./start-vm.sh "$example" 2>&1 | tee "$launcher_log"
  ) &

  if ! wait_for_ssh; then
    cat "$launcher_log" >&2 || true
    log "VM did not become reachable for ${example}"
    return 1
  fi

  log "running VM-backed validation for ${example}"
  stage_rendered_topology
  run_in_vm_validation

  case "$example" in
    single-wan)
      log "running single-wan post-check"
      check_single_wan
      ;;
    dual-wan-branch-overlay)
      log "running dual-wan-branch-overlay post-check"
      check_dual_wan_overlay
      ;;
    dual-wan-branch-overlay-bgp)
      log "running dual-wan-branch-overlay-bgp post-check"
      check_dual_wan_overlay_bgp
      ;;
    *)
      log "no bespoke post-check defined for ${example}; runtime target presence only"
      ;;
  esac

  log "PASS ${example}"
  shutdown_vm
  rm -f "$launcher_log"
  rm -rf "$tmp_dir"
}

trap 'cleanup_vm; cleanup_ephemeral_state' EXIT
log "resolving locked flake inputs"
labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"
log "resolved network-labs at ${labs_path}"
log "resolved network-control-plane-model at ${cpm_path}"

if [[ "$#" -gt 0 ]]; then
  examples=("$@")
else
  mapfile -t examples < <(discover_examples "$labs_path")
fi

failures=()

for example in "${examples[@]}"; do
  if ! run_example "$example"; then
    failures+=("$example")
    log "FAIL ${example}"
    cleanup_vm
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  log "failing examples: ${failures[*]}"
  exit 1
fi
