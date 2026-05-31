#!/usr/bin/env bash
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-005
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-005
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-003
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-003
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-020
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

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
nix eval --impure --json --expr "import ${inventory_clab}" > "${tmp_dir}/cpm.clab.json.renderer-inventory.json"

TMP_DIR="${tmp_dir}" python3 - <<'PY'
from pathlib import Path
import os
import json

from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.Unit.base import render_units

tmp = Path(os.environ["TMP_DIR"])

def _render_core(cpm_path: Path):
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
    return site, name, core, exec_cmds

site, core_name, core, execs_clab = _render_core(tmp / "cpm.clab.json")
nat_intent = getattr(site.nodes[core_name], "nat_intent", {}) or {}
families = nat_intent.get("families") or {}

expected4 = [
    name for name in nat_intent.get("masqueradeInterfaces4", [])
]
expected4_sources = [
    prefix for prefix in nat_intent.get("masqueradeSourcePrefixes4", [])
]
expected6 = [
    name for name in nat_intent.get("masqueradeInterfaces6", [])
]

if families.get("ipv4"):
    assert expected4, "CPM enabled NAT44 but did not name masqueradeInterfaces4"
    assert expected4_sources, "CPM enabled NAT44 but did not name masqueradeSourcePrefixes4"
    source_set = ",".join(expected4_sources)
    for ifname in expected4:
        assert any(
            f"ip saddr {{ {source_set} }}" in c
            and f'oifname "{ifname}" masquerade' in c
            for c in execs_clab
        ), (
            f"expected NAT44 on CPM-selected CLAB WAN port {ifname}"
        )
else:
    assert not any("nft add table ip nat" in c for c in execs_clab), (
        "renderer emitted NAT44 even though CPM natIntent.families.ipv4 is false"
    )

if families.get("ipv6"):
    assert expected6, "CPM enabled NAT66 but did not name masqueradeInterfaces6"
    assert any("ip6 nat" in c for c in execs_clab), "expected NAT66 table from CPM natIntent"
    for ifname in expected6:
        assert any('ip6 saddr' in c and f'oifname "{ifname}" masquerade' in c for c in execs_clab), (
            f"expected NAT66 on CPM-selected CLAB WAN port {ifname}"
        )
else:
    assert not any("ip6 nat" in c for c in execs_clab), (
        "renderer emitted NAT66 even though CPM natIntent.families.ipv6 is false"
    )

print("PASS core-nat-inventory")
PY
