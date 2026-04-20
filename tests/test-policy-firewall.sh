#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

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

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

example_dir="${labs_path}/examples/single-wan"
intent="${example_dir}/intent.nix"
inventory="${example_dir}/inventory.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
  "${intent}" \
  "${inventory}" \
  "${tmp_dir}/cpm.json" >/dev/null

TMP_DIR="${tmp_dir}" python3 - <<'PY'
import json
import os
from pathlib import Path

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import _build_eth_maps
from clabgen.s88.Unit.firewall_context import build_policy_firewall_state
from clabgen.s88.CM.policy_firewall import render as render_policy_firewall

p = Path(os.environ["TMP_DIR"]) / "cpm.json"
sites = load_sites(p)
assert sites, "no sites loaded"

site = next(iter(sites.values()))
assert site.policy_node_name, "site.policy_node_name missing"

eth_maps = _build_eth_maps(site)
eth_map = eth_maps.get(site.policy_node_name) or {}
assert eth_map, "eth_map missing for policy node"

state = build_policy_firewall_state(site, site.policy_node_name, eth_map)
rules = state.get("rules") or []
assert isinstance(rules, list) and rules, "policy firewall rules unexpectedly empty"

# Ensure we at least have tenant->wan allow rules (this is required for basic internet).
has_tenant_to_wan = any(
    isinstance(r, dict)
    and r.get("action") == "accept"
    and r.get("dst_tenant") == "wan"
    and r.get("src_tenant") in {"admin", "client", "mgmt"}
    and isinstance(r.get("matches"), list)
    and len(r["matches"]) > 0
    for r in rules
)
assert has_tenant_to_wan, f"missing accept tenant->wan rule in: {rules!r}"

cmds = render_policy_firewall(state)
cmd_str = "\n".join(cmds)
assert "policy drop" in cmd_str
assert "ct state established,related accept" in cmd_str
assert "counter accept" in cmd_str, "no accept rules emitted into nft commands"
print("PASS policy-firewall")
PY
