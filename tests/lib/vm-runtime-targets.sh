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

extract_runtime_target_tenant_dataplane_checks() {
  local cpm_json="$1"

  python3 - <<'PY' "$cpm_json"
import ipaddress
import json
import sys

data = json.load(open(sys.argv[1]))["control_plane_model"]["data"]

def source_in_prefix(cidr):
    iface = ipaddress.ip_interface(cidr)
    network = iface.network
    if iface.ip.version != 4 or network.num_addresses < 4:
        return None
    candidate = network.broadcast_address - 1
    if candidate == iface.ip:
        candidate = network.network_address + 1
    if candidate != iface.ip and candidate in network:
        return str(candidate)
    return None

for enterprise, sites in data.items():
    for site, site_data in sites.items():
        for runtime_name, rt in sorted(site_data.get("runtimeTargets", {}).items()):
            logical = rt.get("logicalNode") or {}
            logical_name = logical.get("name")
            if not logical_name or "-access-" not in logical_name:
                continue
            realization = rt.get("effectiveRuntimeRealization") or {}
            interfaces = realization.get("interfaces") or {}
            default_iface = None
            default_via4 = None
            for iface_name, iface in sorted(interfaces.items()):
                routes = ((iface.get("routes") or {}).get("ipv4")) or []
                for route in routes:
                    if route.get("policyOnly") is True:
                        continue
                    if route.get("dst") != "0.0.0.0/0":
                        continue
                    via4 = route.get("via4")
                    runtime_if = iface.get("runtimeIfName") or iface.get("renderedIfName")
                    if isinstance(via4, str) and via4 and isinstance(runtime_if, str) and runtime_if:
                        default_iface = runtime_if
                        default_via4 = via4
                        break
                if default_iface:
                    break
            if not default_iface or not default_via4:
                continue
            for iface_name, iface in sorted(interfaces.items()):
                kind = iface.get("sourceKind") or iface.get("kind")
                if kind != "tenant":
                    continue
                runtime_if = iface.get("runtimeIfName") or iface.get("renderedIfName")
                addr4 = iface.get("addr4") or ((iface.get("ipv4") or {}).get("address"))
                if not isinstance(runtime_if, str) or not runtime_if:
                    continue
                if not isinstance(addr4, str) or not addr4:
                    continue
                source4 = source_in_prefix(addr4)
                if source4:
                    print(f"{site}\t{logical_name}\t{runtime_if}\t{source4}\t{default_iface}\t{default_via4}")
PY
}

resolve_container_name() {
  local site="$1"
  local logical_name="$2"
  local pattern="^clab-fabric-.*-${site}-${logical_name}$"
  local container

  container="$(ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1")" || return 1
  if [[ -z "${container}" ]]; then
    echo "resolve_container_name: no container matched pattern ${pattern}" >&2
    return 1
  fi
  printf '%s\n' "${container}"
}

resolve_client_container_name() {
  local site="$1"
  local logical_name="$2"
  local tenant_ifname="$3"
  local pattern="^clab-fabric-.*-${site}-client-${logical_name}-${tenant_ifname}$"
  local container

  container="$(ssh_vm "docker ps --format '{{.Names}}' | grep -E '${pattern}' | head -n1")" || return 1
  if [[ -z "${container}" ]]; then
    echo "resolve_client_container_name: no container matched pattern ${pattern}" >&2
    return 1
  fi
  printf '%s\n' "${container}"
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
    if ! ssh_vm_once "
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
      '
    "; then
      return 1
    fi
  done
}

check_runtime_target_tenant_dataplane() {
  local check site logical_name tenant_if source4 default_if default_via4 container

  for check in "$@"; do
    IFS=$'\t' read -r site logical_name tenant_if source4 default_if default_via4 <<<"${check}"
    container="$(resolve_container_name "${site}" "${logical_name}")"
    log "checking ${container} tenant policy route ${source4} iif ${tenant_if} -> ${default_if} via ${default_via4}"
    if ! ssh_vm_once "
      docker exec '${container}' sh -c '
        set -e
        route=\$(ip route get 8.8.8.8 from ${source4} iif ${tenant_if})
        printf \"%s\\n\" \"\$route\"
        printf \"%s\\n\" \"\$route\" | grep -F \"dev ${default_if}\"
        printf \"%s\\n\" \"\$route\" | grep -F \"via ${default_via4}\"
      '
    "; then
      return 1
    fi
  done
}
