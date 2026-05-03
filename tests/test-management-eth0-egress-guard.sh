#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source "${repo_root}/tests/lib/input-path.sh"

cpm_path="$(resolve_input_path network-control-plane-model)"
labs_path="$(resolve_input_path network-labs)"

example_dir="${labs_path}/examples/s-router-test-three-site"
intent="${example_dir}/intent.nix"
inventory_clab="${example_dir}/inventory-clab.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
  "${intent}" \
  "${inventory_clab}" \
  "${tmp_dir}/cpm.json" >/dev/null

nix eval --impure --json --expr "import ${inventory_clab}" \
  > "${tmp_dir}/cpm.json.renderer-inventory.json"

TMP_DIR="${tmp_dir}" python3 - <<'PY'
from pathlib import Path
import json
import os

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import render_units

tmp_dir = Path(os.environ["TMP_DIR"])
cpm_path = tmp_dir / "cpm.json"
inventory_path = cpm_path.with_suffix(cpm_path.suffix + ".renderer-inventory.json")
renderer_inventory = json.loads(inventory_path.read_text())

sites = load_sites(cpm_path, renderer_inventory=renderer_inventory)
for site_name, site in sites.items():
    nodes, _links, _bridges = render_units(site)
    for node_name, node in nodes.items():
        assert node.get("network-mode") == "none", (
            f"{site_name}/{node_name} must disable Containerlab management networking"
        )
        exec_commands = node.get("exec") or []
        commands = "\n".join(exec_commands)
        assert "nft add table inet clab_guard" in commands, (
            f"{site_name}/{node_name} missing clab_guard table"
        )
        assert "hook output priority -300" in commands, (
            f"{site_name}/{node_name} missing early output guard"
        )
        assert "hook forward priority -300" in commands, (
            f"{site_name}/{node_name} missing early forward guard"
        )
        assert 'nft add rule inet clab_guard output oifname "eth0" drop' in commands, (
            f"{site_name}/{node_name} missing eth0 output drop"
        )
        assert 'nft add rule inet clab_guard forward oifname "eth0" drop' in commands, (
            f"{site_name}/{node_name} missing eth0 forward drop"
        )

print("PASS management-eth0-egress-guard")
PY
