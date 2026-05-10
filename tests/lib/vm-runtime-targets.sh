#!/usr/bin/env bash
set -euo pipefail

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

extract_runtime_target_dataplane_checks() {
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
            realization = rt.get("effectiveRuntimeRealization") or {}
            loopback = realization.get("loopback") or {}
            loop4 = (loopback.get("addr4") or "").split("/", 1)[0]
            loop6 = (loopback.get("addr6") or "").split("/", 1)[0]
            if logical_name and (loop4 or loop6):
                print(f"{site}\t{logical_name}\t{loop4}\t{loop6}")
PY
}

resolve_container_name() {
  local site="$1"
  local logical_name="$2"
  local pattern="^clab-fabric-.*-${site}-${logical_name}$"

  ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1"
}

resolve_client_container_name() {
  local site="$1"
  local logical_name="$2"
  local tenant_ifname="$3"
  local pattern="^clab-fabric-.*-${site}-client-${logical_name}-${tenant_ifname}$"

  ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1"
}

check_runtime_target_suffixes_present() {
  local suffix site logical_name pattern deadline found

  for suffix in "$@"; do
    site="${suffix%%:*}"
    logical_name="${suffix#*:}"
    pattern="^clab-fabric-.*-${site}-${logical_name}\$"
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

check_runtime_target_dataplane() {
  local check site logical_name loop4 loop6 container

  for check in "$@"; do
    IFS=$'\t' read -r site logical_name loop4 loop6 <<<"${check}"
    container="$(resolve_container_name "${site}" "${logical_name}")"
    log "checking ${container} loopback/routes from CPM runtime target ${site}:${logical_name}"
    ssh_vm_once "
      docker exec '${container}' sh -c '
        set -e
        ip -br link
        ip -br addr
        ip route
        ip -6 route
        if [ -n \"${loop4}\" ]; then
          ip route get \"${loop4}\" | grep -F \"dev lo\"
        fi
        if [ -n \"${loop6}\" ]; then
          ip -6 route get \"${loop6}\" | grep -F \"dev lo\"
        fi
        case \"${logical_name}\" in
          *-access-*)
            ip route get 8.8.8.8 >/dev/null
            ip -6 route get 2001:db8::1 >/dev/null
            ;;
        esac
      '
    "
  done
}
