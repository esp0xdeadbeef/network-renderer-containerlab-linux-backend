#!/usr/bin/env bash
set -euo pipefail

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
    _, siteb_core_site, siteb_core, _ = find_rt("b-router-core-nebula")
    _, branch_site, branch_access, branch_rt = find_rt("b-router-access-branch")
    _, sitea_mgmt_site, sitea_mgmt, sitea_rt = find_rt("s-router-access-mgmt")
    branch_loop = (((branch_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    sitea_loop = (((sitea_rt.get("effectiveRuntimeRealization") or {}).get("loopback")) or {})
    emit("SITEA_CORE_RT", sitea_core)
    emit("SITEA_CORE_SITE", sitea_core_site)
    emit("SITEA_CORE_LOGICAL", "s-router-core-isp-a")
    emit("SITEB_CORE_RT", siteb_core)
    emit("SITEB_CORE_SITE", siteb_core_site)
    emit("SITEB_CORE_LOGICAL", "b-router-core-nebula")
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

load_example_context() {
  local example="$1"
  local cpm_json="$2"
  local context
  context="$(extract_example_context "${example}" "${cpm_json}")"
  if [[ -z "${context}" ]]; then
    echo "failed to extract example context for ${example}" >&2
    exit 1
  fi

  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    printf -v "$key" '%s' "$value"
    export "$key"
  done < <(printf '%s\n' "${context}")
}
