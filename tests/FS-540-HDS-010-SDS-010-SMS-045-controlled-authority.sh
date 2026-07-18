#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-045
# GAMP-SCOPE: CLAB controlled iterative authority materialization
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nix eval --json --impure --expr '
let
  cpmFlake = builtins.getFlake (toString /home/deadbeef/github/network-control-plane-model);
  labs = /home/deadbeef/github/network-labs;
  system = builtins.currentSystem;
  trace = "FS-540-HDS-010-SDS-010-SMS-045";
  row = labs + "/GAMP/SMT/${trace}";
  inventory = import (row + "/inventory-clab.nix");
  built = cpmFlake.libBySystem.${system}.compileAndBuild {
    input = import (row + "/intent.nix");
    inherit inventory;
  };
in built.control_plane_model
' >"${tmp_dir}/cpm.json"

nix eval --json --file \
  /home/deadbeef/github/network-labs/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-045/inventory-clab.nix \
  >"${tmp_dir}/inventory.json"

CPM_JSON="${tmp_dir}/cpm.json" \
INVENTORY_JSON="${tmp_dir}/inventory.json" \
REPO_ROOT="${repo_root}" \
PYTHONPATH="${repo_root}" \
python3 - <<'PY'
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shlex
import tempfile

from clabgen.cpm_solver import control_plane_model_to_solver_json
from clabgen.s88.enterprise.enterprise import Enterprise
from clabgen.s88.CM.dns_service import render_dns_service
from clabgen.s88.site.model_builder import build_nodes, tenant_prefix_owners
from clabgen.s88.site.naming import realized_bridge_name
from clabgen.s88.site.node_runtime import build_node_data


with open(os.environ["CPM_JSON"], encoding="utf-8") as handle:
    cpm = json.load(handle)
with open(os.environ["INVENTORY_JSON"], encoding="utf-8") as handle:
    inventory = json.load(handle)
inventory.setdefault("containerlab", {})["targetHost"] = "s-router-clab"

solver = control_plane_model_to_solver_json({"control_plane_model": cpm})
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
    json.dump(solver, handle)
    handle.flush()
    rendered = Enterprise.from_solver_json(
        handle.name,
        renderer_inventory=inventory,
    ).render()

artifacts = rendered["lab_emulation_artifacts"]
assert len(artifacts) == 1
artifact = artifacts[0]
authority = artifact["dnsValidationAuthority"]
assert artifact["scope"] == "harness"
assert artifact["providerEmulationMode"] == "fake-provider"
assert artifact["providerBridge"] == authority["provider"]["bridge"]
assert artifact["selectedUplink"] == "isp-primary"
assert artifact["alternateUplinks"] == ["overlay-secondary"]

provider_nodes = [
    (name, node)
    for name, node in rendered["topology"]["nodes"].items()
    if node.get("labels", {}).get("clab.dns.validation-authority")
    == "controlled-iterative-hierarchy"
]
assert len(provider_nodes) == 1
provider_name, provider = provider_nodes[0]
provider_script = "\n".join(
    shlex.split(command)[2]
    for command in provider["exec"]
    if shlex.split(command)[:2] == ["sh", "-c"]
)
for required in (
    "dnsmasq --test",
    "enable-ra",
    "constructor:",
    "ra-only,slaac,64",
    "knotc --config=/run/clabgen-knot.conf conf-check",
    "knotc --config=/run/clabgen-knot.conf zone-check . dns-validation.test.",
    "knotd --config=/run/clabgen-knot.conf --daemonize",
    "dns-validation.test.",
    "answer.dns-validation.test.",
):
    assert required in provider_script, required

provider_links = [
    link
    for link in rendered["topology"]["links"]
    if any(endpoint.startswith(f"{provider_name}:") for endpoint in link["endpoints"])
]
assert len(provider_links) == 1
assert provider_links[0]["labels"]["clab.link.bridge"] == "isp-primary"
assert all(
    link["labels"].get("clab.link.bridge") != "overlay-secondary"
    for link in provider_links
)


def core_provider_link(interface: str, bridge: str) -> dict:
    matches = [
        link
        for link in rendered["topology"]["links"]
        if link["labels"].get("clab.link.bridge") == bridge
        and any(
            "core-primary" in endpoint.split(":", 1)[0]
            and endpoint.endswith(f":{interface}")
            for endpoint in link["endpoints"]
        )
    ]
    core_links = [
        link
        for link in rendered["topology"]["links"]
        if any("core-primary" in endpoint for endpoint in link["endpoints"])
    ]
    assert len(matches) == 1, (interface, bridge, core_links)
    return matches[0]


for interface, source_bridge in (
    ("wan0", "isp-primary"),
    ("wan1", "overlay-secondary"),
):
    bridge = realized_bridge_name(source_bridge)
    core_link = core_provider_link(interface, bridge)
    bridge_endpoints = [
        endpoint
        for endpoint in core_link["endpoints"]
        if endpoint.startswith(f"{bridge}:")
    ]
    assert len(bridge_endpoints) == 1, core_link
    assert all(not endpoint.startswith("host:") for endpoint in core_link["endpoints"])

site_data = next(
    site
    for enterprise in solver["enterprise"].values()
    for site in enterprise["site"].values()
)
core_model = build_nodes(site_data, tenant_prefix_owners(site_data))["core-primary"]
core_eth_map = {
    ifname: (interface.runtime_if_name or f"eth{index}")
    for index, (ifname, interface) in enumerate(core_model.interfaces.items(), 1)
}
core = build_node_data("core-primary", core_model, core_eth_map)
core_script = shlex.split(render_dns_service(core, "core-primary")[0])[2]
assert 'root-hints: "/tmp/clabgen-controlled-root.hints"' in core_script
assert 'domain-insecure: "."' in core_script
assert "auto-trust-anchor-file" not in core_script
assert "/usr/share/dns/root.key" not in core_script

bad_core = copy.deepcopy(core)
bad_core["services"]["dns"]["validationAuthority"]["selectedUplink"] = (
    "overlay-secondary"
)
try:
    render_dns_service(bad_core, "core-primary")
except ValueError as error:
    diagnostic = str(error)
    assert "DNS_VALIDATION_AUTHORITY_EXTERNAL" in diagnostic
    assert "198.18." not in diagnostic
    assert "fd42:" not in diagnostic
else:
    raise AssertionError("seeded selected-uplink divergence was accepted")

dockerfile = (Path(os.environ["REPO_ROOT"]) / "docker-clab-frr-plus-tooling/Dockerfile").read_text()
for package in ("dnsmasq", "knot"):
    assert f"        {package} \\" in dockerfile

print("PASS FS-540 CLAB controlled iterative authority materialization")
PY
