#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source "${repo_root}/tests/lib/input-path.sh"

cpm_path="$(resolve_input_path network-control-plane-model)"
labs_path="$(resolve_input_path network-labs)"

example_dir="${labs_path}/examples/single-wan"
intent="${example_dir}/intent.nix"
inventory_clab="${example_dir}/inventory-clab.nix"
[[ -f "${inventory_clab}" ]] || { echo "missing inventory-clab.nix: ${inventory_clab}" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

build_cpm() {
  local inventory="$1"
  local out="$2"
nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${intent}" \
    "${inventory}" \
    "${out}" >/dev/null
}

build_cpm "${inventory_clab}" "${tmp_dir}/cpm.clab.json"

# Renderer inventory is derived from the flake-locked containerlab inventory input.
nix eval --impure --json --expr "let inv = import ${inventory_clab}; in { containerlab = inv.containerlab or {}; }" > "${tmp_dir}/cpm.clab.json.renderer-inventory.json"

TMP_DIR="${tmp_dir}" python3 - <<'PY'
from pathlib import Path
import os
import json

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import render_units

tmp = Path(os.environ["TMP_DIR"])

def _render_execs(cpm_path: Path) -> list[str]:
    inv_path = cpm_path.with_suffix(cpm_path.suffix + ".renderer-inventory.json")
    inv = json.loads(inv_path.read_text())
    if not isinstance(inv, dict):
        raise TypeError("renderer inventory must be a JSON object")

    site = next(iter(load_sites(cpm_path, renderer_inventory=inv).values()))
    nodes, _links, _bridges = render_units(site)

    core_names = [
        n for n, obj in site.nodes.items() if getattr(obj, "role", None) == "core"
    ]
    assert core_names, "no core nodes in site model"

    name = core_names[0]
    core = nodes.get(name) or {}
    exec_cmds = core.get("exec") or []
    assert isinstance(exec_cmds, list) and exec_cmds, "missing core exec commands"
    return exec_cmds

execs_clab = _render_execs(tmp / "cpm.clab.json")

want = 'oifname "eth0" masquerade'
want6 = 'oifname "eth0" masquerade'

assert any(want in c for c in execs_clab), "expected NAT44 on eth0 via inventory-clab.nix"
assert any("ip6 nat" in c for c in execs_clab), "expected NAT66 table via inventory-clab.nix"
assert any('ip6 saddr' in c and 'oifname "eth0" masquerade' in c for c in execs_clab), "expected NAT66 on eth0 via inventory-clab.nix"

print("PASS core-nat-inventory")
PY
