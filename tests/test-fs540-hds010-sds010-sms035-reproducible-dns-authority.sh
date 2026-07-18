#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-035
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

REPO_ROOT="${repo_root}" nix eval --json --impure --expr '
let
  repoRoot = builtins.getEnv "REPO_ROOT";
  flake = builtins.getFlake ("path:" + repoRoot);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  traceId = "FS-540-HDS-010-SDS-010-SMS-030";
  source = import (labs + "/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-030/intent.nix");
  inventory = import (labs + "/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-030/inventory-clab.nix");
  built = flake.inputs.network-control-plane-model.libBySystem.${system}.compileAndBuild {
    input = source;
    inherit inventory;
  };
in
built.control_plane_model
' >"${tmp_dir}/cpm.json"

unbound_out="$(nix eval --raw nixpkgs#unbound.outPath)"
dns_root_out="$(nix eval --raw nixpkgs#dns-root-data.outPath)"

CPM_JSON="${tmp_dir}/cpm.json" \
UNBOUND_CHECKCONF="${unbound_out}/bin/unbound-checkconf" \
UNBOUND_ROOT_KEY="${dns_root_out}/root.key" \
REPO_ROOT="${repo_root}" \
PYTHONPATH="${repo_root}" \
python3 - <<'PY'
from __future__ import annotations

import copy
from ipaddress import ip_address, ip_interface, ip_network
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

from clabgen.s88.CM.dns_service import render_dns_service
from clabgen.s88.CM.linux_wan_dynamic import render as render_dynamic_wan
from clabgen.cpm_solver import control_plane_model_to_solver_json
from clabgen.s88.site.model_builder import build_nodes, tenant_prefix_owners
from clabgen.s88.site.node_runtime import build_node_data, render_linux_node


with open(os.environ["CPM_JSON"], encoding="utf-8") as handle:
    cpm = json.load(handle)

solver = control_plane_model_to_solver_json({"control_plane_model": cpm})
sites = [
    site
    for enterprise in solver["enterprise"].values()
    for site in enterprise["site"].values()
]
assert len(sites) == 1
site = sites[0]
models = build_nodes(site, tenant_prefix_owners(site))
targets = {}
eth_maps = {}
for name, model in models.items():
    eth_map = {
        ifname: (iface.runtime_if_name or f"eth{index}")
        for index, (ifname, iface) in enumerate(model.interfaces.items(), 1)
    }
    eth_maps[name] = eth_map
    targets[name] = build_node_data(name, model, eth_map)


def target_for(logical_name):
    return targets[logical_name]


def rendered_script(target):
    commands = render_dns_service(target, target["name"])
    assert len(commands) == 1
    argv = shlex.split(commands[0])
    assert argv[:2] == ["sh", "-c"]
    return argv[2]


def unbound_config(script):
    match = re.search(
        r"cat >/tmp/clabgen-unbound[.]conf <<'UNBOUND'\n(.*?)\nUNBOUND\n",
        script,
        re.DOTALL,
    )
    assert match is not None
    return match.group(1)


def unbound_reconcile_script(script):
    match = re.search(
        r"cat >/tmp/clabgen-reconcile-unbound[.]sh <<'RECONCILE_UNBOUND'\n(.*?)\nRECONCILE_UNBOUND\n",
        script,
        re.DOTALL,
    )
    assert match is not None
    return match.group(1)


recursive = target_for("access-recursive")
local = target_for("access-local")
core = target_for("core-primary")

recursive_script = rendered_script(recursive)
local_script = rendered_script(local)
core_script = rendered_script(core)
core_dynamic_commands = render_dynamic_wan(core, eth_maps["core-primary"])
core_dynamic_payloads = [shlex.split(command)[2] for command in core_dynamic_commands]
core_dynamic_script = "\n".join(core_dynamic_payloads)
recursive_config = unbound_config(recursive_script)
local_config = unbound_config(local_script)
core_config = unbound_config(core_script)
core_reconcile_script = unbound_reconcile_script(core_script)


def check_config(config):
    rendered = config.replace(
        "/tmp/clabgen-unbound-root.key", os.environ["UNBOUND_ROOT_KEY"]
    ).replace('username: "unbound"', 'username: ""')
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        result = subprocess.run(
            [os.environ["UNBOUND_CHECKCONF"], handle.name],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    assert result.returncode == 0


for config in (recursive_config, local_config, core_config):
    check_config(config)

assert "clabgen-dns-proxy.py" not in recursive_script + local_script + core_script
assert "unbound-checkconf /tmp/clabgen-unbound.conf" in recursive_script
assert "nohup unbound -d -c /tmp/clabgen-unbound.conf" in core_script
assert 'username: "unbound"' in core_config
assert 'username: ""' not in core_config
assert "DNS listener endpoints did not become available" in core_script
assert "tentative|dadfailed" in core_script
assert "DNS resolver did not remain available" in core_script
assert core_reconcile_script.count("for attempt in $(seq 1 3000)") == 1
assert core_reconcile_script.count("for attempt in $(seq 1 600)") == 1
assert '$4 == address || index($4, address "/") == 1' in core_reconcile_script
assert "for attempt in $(seq 1 100)" not in core_script
assert core_script.rstrip().endswith("chmod 0700 /tmp/clabgen-reconcile-unbound.sh")

recursive_dns = recursive["services"]["dns"]
core_dns = core["services"]["dns"]
named_core = next(
    resolver
    for resolver in recursive_dns["upstreamResolvers"]
    if resolver.get("kind") == "named-core-resolver"
)
core_endpoint_binding = core_dns["serviceEndpointBindings"][0]
assert named_core["endpointAuthority"]["relationId"] == core_endpoint_binding["relationId"]
assert (
    named_core["endpointAuthority"]["terminalAttachmentId"]
    == core_endpoint_binding["terminalAttachmentId"]
)
assert core_endpoint_binding["addresses"] == core_dns["listen"]
terminal_interfaces = [
    interface
    for interface in core["interfaces"].values()
    if interface.get("backingRef", {}).get("id")
    == core_endpoint_binding["terminalAttachmentId"]
]
assert len(terminal_interfaces) == 1
terminal_ifname = terminal_interfaces[0]["runtimeIfName"]
terminal_addresses = {
    ip_interface(terminal_interfaces[0][key]).ip
    for key in ("addr4", "addr6")
    if terminal_interfaces[0].get(key)
}
assert {ip_address(address) for address in core_endpoint_binding["addresses"]} == terminal_addresses
for address in core_endpoint_binding["addresses"]:
    parsed = ip_address(address)
    prefix = 128 if parsed.version == 6 else 32
    family = "ip -6" if parsed.version == 6 else "ip"
    fragment = f"{family} addr replace {parsed}/{prefix} dev {terminal_ifname}"
    assert fragment not in core_script

distinct_endpoint = copy.deepcopy(core)
distinct_addresses = [
    str(ip_address(int(ip_address(address)) + 1024))
    for address in core_endpoint_binding["addresses"]
]
distinct_endpoint["services"]["dns"]["listen"] = distinct_addresses
distinct_endpoint["services"]["dns"]["serviceEndpointBindings"][0][
    "addresses"
] = distinct_addresses
distinct_script = rendered_script(distinct_endpoint)
for address in distinct_addresses:
    parsed = ip_address(address)
    prefix = 128 if parsed.version == 6 else 32
    family = "ip -6" if parsed.version == 6 else "ip"
    fragment = f"{family} addr replace {parsed}/{prefix} dev {terminal_ifname}"
    assert fragment in distinct_script
    assert distinct_script.index(fragment) < distinct_script.index(
        "nohup unbound -d -c /tmp/clabgen-unbound.conf"
    )
assert 'forward-zone:\n  name: "."' in recursive_config
for address in named_core["addresses"]:
    assert f'forward-addr: "{ip_address(address)}"' in recursive_config
for policy in recursive_dns["requesterPolicies"]:
    assert policy["action"] == "refuse_non_local"
    for prefix in policy["sourcePrefixes"]:
        assert f'access-control: "{ip_network(prefix, strict=False)}" refuse_non_local' in recursive_config

local_dns = local["services"]["dns"]
assert 'local-zone: "." static' in local_config
assert 'forward-zone:\n  name: "."' not in local_config
for zone in local_dns["localForwardZones"]:
    assert f'forward-zone:\n  name: "{zone["name"]}"' in local_config
    assert "forward-first: no" in local_config
    for address in zone["forwardTo"]:
        assert f'forward-addr: "{ip_address(address)}"' in local_config
for policy in local_dns["requesterPolicies"]:
    assert policy["action"] == "refuse_non_local"
    for prefix in policy["sourcePrefixes"]:
        assert f'access-control: "{ip_network(prefix, strict=False)}" refuse_non_local' in local_config
assert 'local-zone: "lab." transparent' in local_config
assert 'local-zone: "lab." static' not in local_config

assert "forward-zone:" not in core_config
assert 'auto-trust-anchor-file: "/tmp/clabgen-unbound-root.key"' in core_config
assert "install -o unbound -g unbound -m 0600 /usr/share/dns/root.key" in core_script

core_origin = core["runtimeOriginEgress"]
core_policy = core_origin["policyRouting"]
assert core_origin["policyRoutingRequired"] is True
assert core_origin["uplinks"] == [core_policy["selectedUplink"]]
assert core_policy["source"] == "control-plane-model"
mark = core_policy["firewallMark"]
priority = core_policy["rulePriority"]
table = core_policy["tableId"]
for fragment in (
    "nft add table inet s88_dns_egress",
    "type route hook output priority mangle; policy accept;",
    f"udp dport 53 meta mark set {mark}",
    f"tcp dport 53 meta mark set {mark}",
    f"ip rule add fwmark {mark} priority {priority} table {table}",
    f"ip -6 rule add fwmark {mark} priority {priority} table {table}",
    'dns_service_uid="$(id -u unbound)"',
    f'ip rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" priority {priority} table {table}',
    f'ip -6 rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" priority {priority} table {table}',
):
    assert fragment in core_script
assert core_script.index("nft add table inet s88_dns_egress") < core_script.index(
    "cat >/tmp/clabgen-reconcile-unbound.sh"
)
for fragment in (
    "/run/udhcpc.wan0.s88-table-1002",
    'ip -4 route replace table 1002 default via "$router" dev "$interface"',
    "/run/s88-ra-route-wan0-table-1002.sh",
    "route=\"$(ip -6 route show table main default dev wan0 | sed -n '1s/^default //; s/ expires [^ ]*//; p')\"",
    "selected_route=\"$(ip -6 route show table 1002 default dev wan0 | sed -n '1s/ expires [^ ]*//; p')\"",
    'if [ "default $route" != "$selected_route" ]; then',
    "ip -6 route replace table 1002 default $route dev wan0",
    "ip -6 monitor route dev wan0",
):
    assert fragment in core_dynamic_script, (fragment, core_dynamic_script)
assert "${route#" not in core_dynamic_script
ra_route_sample = subprocess.run(
    ["sed", "-n", "1s/^default //; s/ expires [^ ]*//; p"],
    input="default via fe80::1 proto ra metric 1024 expires 75sec pref medium\n",
    text=True,
    capture_output=True,
    check=True,
).stdout.strip()
assert ra_route_sample == "via fe80::1 proto ra metric 1024 pref medium"
assert "dev wan0" in core_dynamic_script
for command, payload in zip(core_dynamic_commands, core_dynamic_payloads, strict=True):
    argv = shlex.split(command)
    assert argv[:2] == ["sh", "-c"]
    assert subprocess.run(["sh", "-n", "-c", payload], check=False).returncode == 0


def rejected(target, code):
    try:
        rendered_script(target)
    except ValueError as error:
        diagnostic = str(error)
        assert code in diagnostic
        assert not re.search(r"(?:[0-9]{1,3}\.){3}[0-9]{1,3}", diagnostic)
        assert not re.search(r"(?:[0-9A-Fa-f]{0,4}:){2,}", diagnostic)
        return
    raise AssertionError(f"seeded negative did not raise {code}")


leaking = copy.deepcopy(local)
leaking["services"]["dns"]["localOnlyPolicy"]["recursion"] = True
rejected(leaking, "DNS_LOCAL_ONLY_AUTHORITY_LEAK")

divergent = copy.deepcopy(recursive)
divergent["services"]["dns"]["forwarders"] = ["seeded-mismatch"]
rejected(divergent, "DNS_RENDERER_CONTRACT_DIVERGENCE")

missing_endpoint_authority = copy.deepcopy(recursive)
next(
    resolver
    for resolver in missing_endpoint_authority["services"]["dns"]["upstreamResolvers"]
    if resolver.get("kind") == "named-core-resolver"
).pop("endpointAuthority")
rejected(missing_endpoint_authority, "DNS_RENDERER_CONTRACT_DIVERGENCE")

divergent_core_endpoint = copy.deepcopy(core)
divergent_core_endpoint["services"]["dns"]["serviceEndpointBindings"][0]["addresses"] = [
    "seeded.v4",
    "seeded:v6",
]
rejected(divergent_core_endpoint, "DNS_RENDERER_CONTRACT_DIVERGENCE")

unbound_core_endpoint = copy.deepcopy(core)
unbound_core_endpoint["services"]["dns"]["serviceEndpointBindings"][0][
    "terminalAttachmentId"
] = "link::seeded-missing-terminal"
rejected(unbound_core_endpoint, "DNS_RENDERER_CONTRACT_DIVERGENCE")

missing_egress_policy = copy.deepcopy(core)
missing_egress_policy["runtimeOriginEgress"].pop("policyRouting")
rejected(missing_egress_policy, "DNS_RENDERER_CONTRACT_DIVERGENCE")

divergent_egress_allocation = copy.deepcopy(core)
selected_name = divergent_egress_allocation["runtimeOriginEgress"]["policyRouting"][
    "selectedInterface"
]
divergent_egress_allocation["interfaces"][selected_name][
    "policyRoutingAllocation"
]["tableId"] += 1
rejected(divergent_egress_allocation, "DNS_RENDERER_CONTRACT_DIVERGENCE")

shadowed_namespace = copy.deepcopy(local)
next(
    zone
    for zone in shadowed_namespace["services"]["dns"]["localZones"]
    if zone.get("name") == "lab."
)["type"] = "static"
rejected(shadowed_namespace, "DNS_LOCAL_NAMESPACE_SHADOWED")

fatal = copy.deepcopy(recursive)
fatal["services"]["dns"]["reproducibilityWarnings"] = [
    {"code": "DNS_EGRESS_SELECTION_AMBIGUOUS", "disposition": "fail-closed"}
]
rejected(fatal, "DNS_EGRESS_SELECTION_AMBIGUOUS")

warned = copy.deepcopy(recursive)
warned["services"]["dns"]["reproducibilityWarnings"] = [
    {"code": "DNS_CORE_UPSTREAM_HARDCODED", "disposition": "warn"}
]
warning_script = rendered_script(warned)
assert "DNS_CORE_UPSTREAM_HARDCODED" in warning_script
assert "address material is intentionally omitted" in warning_script

for name in ("access-recursive", "access-local", "core-primary"):
    rendered_node = render_linux_node(name, models[name], eth_maps[name])
    assert rendered_node["labels"]["clab.dns.runtime"] == "unbound"
policy_node = render_linux_node("policy", models["policy"], eth_maps["policy"])
assert "clab.dns.runtime" not in policy_node["labels"]

repo_root = Path(os.environ["REPO_ROOT"])
host_module = (repo_root / "host-module.nix").read_text(encoding="utf-8")
deploy_clab = (repo_root / "deploy-clab.sh").read_text(encoding="utf-8")
for content in (host_module, deploy_clab):
    assert "label=clab.dns.runtime=unbound" in content
    assert "/tmp/clabgen-reconcile-unbound.sh" in content
assert "reconcile-dns-services.sh" in host_module
deploy_pos = host_module.index("bash '$work_dir/deploy-containerlab-on-host.sh'")
post_bridge_pos = host_module.index("bash '$work_dir/setup-bridge-links.sh'", deploy_pos)
dns_reconcile_pos = host_module.index("bash '$work_dir/reconcile-dns-services.sh'", deploy_pos)
verify_pos = host_module.index("bash '$work_dir/verify-containerlab-deploy.sh'", deploy_pos)
assert deploy_pos < post_bridge_pos < dns_reconcile_pos < verify_pos
assert "reconcile_dns_services \"${name}\"" in deploy_clab
assert deploy_clab.index('reconcile_dns_services "${name}"') < deploy_clab.index(
    'verify_fabric_containers "${name}"'
)

print("PASS FS-540 CLAB reproducible DNS authority materialization")
PY
