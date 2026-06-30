#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

labs_path="${NETWORK_LABS_PATH:-${NETWORK_INPUT_PATH_NETWORK_LABS:-}}"
if [[ -z "${labs_path}" && -d "${repo_root}/../network-labs/current-lab" ]]; then
  labs_path="$(cd "${repo_root}/../network-labs" && pwd)"
fi

cpm_path="${NETWORK_CPM_PATH:-${NETWORK_INPUT_PATH_NETWORK_CONTROL_PLANE_MODEL:-}}"
if [[ -z "${cpm_path}" && -d "${repo_root}/../network-control-plane-model" ]]; then
  cpm_path="$(cd "${repo_root}/../network-control-plane-model" && pwd)"
fi

if [[ -z "${labs_path}" || ! -f "${labs_path}/current-lab/metadata.nix" ]]; then
  echo "FAIL FS-380 active-lab CLAB render: missing network-labs current-lab" >&2
  exit 1
fi

if [[ -z "${cpm_path}" || ! -f "${cpm_path}/flake.nix" ]]; then
  echo "FAIL FS-380 active-lab CLAB render: missing network-control-plane-model path" >&2
  exit 1
fi

selection_trace="$(
  LABS_PATH="${labs_path}" nix eval --impure --raw --expr '
    let current = import ((builtins.getEnv "LABS_PATH") + "/current-lab");
    in current.selection.traceId or ""
  '
)"
if [[ "${selection_trace}" != "FS-380-HDS-020-SDS-010" ]]; then
  echo "FAIL FS-380 active-lab CLAB render: current-lab must be selected to SIT FS-380-HDS-020-SDS-010, got ${selection_trace}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nix run --show-trace "path:${cpm_path}#compile-and-build-control-plane-model" -- \
  "${labs_path}/current-lab/intent-s-router-clab.nix" \
  "${labs_path}/current-lab/inventory-s-router-clab.nix" \
  "${tmp_dir}/cpm.json" >/dev/null

nix eval --impure --json --expr \
  "import ${labs_path}/current-lab/inventory-s-router-clab.nix" \
  >"${tmp_dir}/renderer-inventory.json"

CLABGEN_RENDERER_INVENTORY_JSON="${tmp_dir}/renderer-inventory.json" \
  nix run --show-trace "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/cpm.json" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/vm-bridges-generated.nix" >/dev/null

upstream_node_block="$(
  awk '
    $0 == "    mini-smt-internet-mode-verification-upstream-selector:" { in_node = 1; print; next }
    in_node && /^    [^ ].*:$/ { exit }
    in_node { print }
  ' "${tmp_dir}/fabric.clab.yml"
)"
upstream_node_flat="$(tr '\n' ' ' <<<"${upstream_node_block}" | sed -E 's/[[:space:]]+/ /g')"

policy_node_block="$(
  awk '
    $0 == "    mini-smt-internet-mode-verification-policy:" { in_node = 1; print; next }
    in_node && /^    [^ ].*:$/ { exit }
    in_node { print }
  ' "${tmp_dir}/fabric.clab.yml"
)"
policy_node_flat="$(tr '\n' ' ' <<<"${policy_node_block}" | sed -E 's/[[:space:]]+/ /g')"

require_line() {
  local expected="$1"
  if ! grep -Fq -- "${expected}" <<<"${upstream_node_flat}"; then
    echo "FAIL FS-380 active-lab CLAB render: missing upstream-selector command: ${expected}" >&2
    printf '%s\n' "${upstream_node_block}" >&2
    exit 1
  fi
}

require_policy_line() {
  local expected="$1"
  if ! grep -Fq -- "${expected}" <<<"${policy_node_flat}"; then
    echo "FAIL FS-380 active-lab CLAB render: missing policy-node command: ${expected}" >&2
    printf '%s\n' "${policy_node_block}" >&2
    exit 1
  fi
}

require_line "ip route replace table 1001 10.20.20.0/24 nexthop via 10.10.0.6 dev p1 onlink nexthop via 10.10.0.8 dev p2 onlink"
require_line "ip route replace table 1002 0.0.0.0/0 via 10.10.0.4 dev p0 onlink"
require_line "ip route replace table 1003 0.0.0.0/0 via 10.10.0.4 dev p0 onlink"
require_line "sh -c 'ip rule add iif p0 priority 10001 table 1001 2>/dev/null || true'"
require_line "sh -c 'ip rule add iif p1 priority 10002 table 1002 2>/dev/null || true'"
require_line "sh -c 'ip rule add iif p2 priority 10003 table 1003 2>/dev/null || true'"

require_policy_line "sh -c 'ip route replace table 1002 10.20.20.0/24 via 10.10.0.2 dev p0 onlink 2>/dev/null || true'"
require_policy_line "sh -c 'ip -6 route replace table 1002 fd42:380:20::/64 via fd42:380:ff:0:0:0:0:2 dev p0 onlink 2>/dev/null || true'"

grep -F 'lab-emulation-fs380-internet-mode-provider:' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'clab.lab-emulation: fake-provider' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'clab.link.type: lab-emulation' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'clab.link.bridge: internet-vlan4' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -E 'ip addr replace 10\.20\.0\.1/24 dev veth-[0-9a-f]{10}' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'udhcpd /run/udhcpd/fake-provider.conf' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'ip saddr 10.20.0.0/24 masquerade' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'ip addr replace 10.20.0.20/24 dev u0' "${tmp_dir}/fabric.clab.yml" >/dev/null
grep -F 'ip route replace default via 10.20.0.1 dev u0 onlink' "${tmp_dir}/fabric.clab.yml" >/dev/null
if grep -F 'udhcpc -b -i u0' "${tmp_dir}/fabric.clab.yml" >/dev/null; then
  echo "FAIL FS-380 active-lab CLAB render: u0 must use explicit fake-provider client binding, not generic DHCP" >&2
  exit 1
fi

python3 - "${tmp_dir}/vm-bridges-generated.nix" <<'PY'
import json
import re
import sys
from pathlib import Path

bridges = Path(sys.argv[1]).read_text()
quote = chr(39) * 2
artifact_match = re.search(
    r"labEmulationArtifacts = builtins\.fromJSON " + quote + r"\n(.*?)\n  " + quote + ";",
    bridges,
    re.S,
)
if not artifact_match:
    raise SystemExit("missing labEmulationArtifacts JSON")
artifacts = json.loads(artifact_match.group(1))
assert len(artifacts) == 1, artifacts
artifact = artifacts[0]
assert artifact["providerEmulationMode"] == "fake-provider", artifact
assert artifact["name"] == "fs380-internet-mode-provider", artifact
assert artifact["scope"] == "harness", artifact
assert artifact["harnessScoped"] is True, artifact
assert artifact["handoffVlan"] == 11, artifact
assert artifact["liveUpstreamVlan"] == 4, artifact
assert artifact["liveUpstreamReachability"] == {"vlan": 4}, artifact
assert artifact["dhcp4"]["address"] == "10.20.0.1/24", artifact
assert artifact["dhcp4"]["router"] == "10.20.0.1", artifact
assert artifact["dhcp4"]["clientAddress"] == "10.20.0.20", artifact
assert artifact["dhcp4"]["rangeStart"] == "10.20.0.20", artifact
assert artifact["dhcp4"]["rangeEnd"] == "10.20.0.99", artifact
assert artifact["dhcp4"]["sourcePrefix"] == "10.20.0.0/24", artifact
assert artifact["nat44"] == {"enabled": True, "sourcePrefix": "10.20.0.0/24"}, artifact

bridge_match = re.search(
    r"bridgeNetworks = builtins\.fromJSON " + quote + r"\n(.*?)\n  " + quote + ";",
    bridges,
    re.S,
)
if not bridge_match:
    raise SystemExit("missing bridgeNetworks JSON")
bridge_networks = json.loads(bridge_match.group(1))
assert bridge_networks["internet-vlan4"]["mode"] == "vlan", bridge_networks
assert bridge_networks["internet-vlan4"]["vlan"] == 4, bridge_networks
PY

echo "PASS FS-380 active-lab CLAB upstream-selector render"
