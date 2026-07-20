#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: Containerlab/Linux renderer construction test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    traceId = "FS-270-HDS-010-SDS-010-SMS-020";
    row = flake.inputs.network-labs.outPath + "/GAMP/SMT/${traceId}";
    cpm = flake.inputs.network-control-plane-model.lib.${system}.compileAndBuild {
      input = import (row + "/intent.nix");
      inventory = import (row + "/inventory-clab.nix");
    };
  in
  {
    inherit (cpm) control_plane_model;
  }
' >"${tmp_dir}/cpm.json"

nix run --no-write-lock-file "path:${repo_root}#generate-clab-config" -- \
    "${tmp_dir}/cpm.json" \
    "${tmp_dir}/fabric.clab.yml" \
    "${tmp_dir}/bridges.nix"

nix shell --inputs-from "${repo_root}" nixpkgs#yq-go --command \
  yq -o=json '.' "${tmp_dir}/fabric.clab.yml" >"${tmp_dir}/fabric.clab.json"

REPO_ROOT="${repo_root}" CPM_JSON="${tmp_dir}/cpm.json" TOPOLOGY="${tmp_dir}/fabric.clab.json" \
  NFT_BATCH="${tmp_dir}/fs270-policy.nft" \
  PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX=/tmp/pycache python3 - <<'PY'
import copy
import json
import ipaddress
import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, os.environ["REPO_ROOT"])

from clabgen.s88.CM.relation_selection_rules import render_relation_selection_rules
from clabgen.s88.CM.cpm_firewall_rules import rules_for_cpm_rule

trace_id = "FS-270-HDS-010-SDS-010-SMS-020"
relation_id = f"{trace_id}__source-to-destination-icmp"

with Path(os.environ["CPM_JSON"]).open(encoding="utf-8") as handle:
    cpm_root = json.load(handle)
with Path(os.environ["TOPOLOGY"]).open(encoding="utf-8") as handle:
    topology = json.load(handle)

site = cpm_root["control_plane_model"]["data"]["mini-smt"][trace_id]
target = next(
    target
    for target in site["runtimeTargets"].values()
    if target["logicalNode"]["name"] == "downstream-selector"
)
effective = target["effectiveRuntimeRealization"]
interfaces = effective["interfaces"]
selectors = [
    selector
    for selector in effective.get("routeSelectionRules", [])
    if selector.get("relationId") == relation_id
]

node_matches = [
    node
    for name, node in topology["topology"]["nodes"].items()
    if name.endswith("-downstream-selector")
]
if len(node_matches) != 1:
    raise AssertionError("rendered downstream-selector identity is not unique")
node = node_matches[0]
commands = "\n".join(node.get("exec", []))

policy_node_matches = [
    node
    for name, node in topology["topology"]["nodes"].items()
    if name.endswith("-policy")
]
if len(policy_node_matches) != 1:
    raise AssertionError("rendered policy owner identity is not unique")
policy_exec = policy_node_matches[0].get("exec", [])

nft_statements = []
primitive_lines = []
for bundled_command in policy_exec:
    outer_argv = shlex.split(bundled_command)
    if len(outer_argv) != 4 or outer_argv[:3] != ["sh", "-e", "-c"]:
        raise AssertionError(
            f"unexpected CLAB exec bundle shape: {outer_argv[:3]!r}"
        )
    primitive_lines.extend(outer_argv[3].splitlines())

for line in primitive_lines:
    try:
        argv = shlex.split(line)
    except ValueError:
        continue
    if (
        len(argv) == 2
        and argv[0] == "nft"
        and argv[1].startswith("add rule inet fw forward ")
    ):
        nft_statements.append(argv[1])

relation_nft_statements = [
    statement for statement in nft_statements if relation_id in statement
]
if len(relation_nft_statements) != 4:
    raise AssertionError(
        "expected four relation-scoped rendered nft statements, got "
        f"{len(relation_nft_statements)}"
    )
if any(
    " icmpv6 counter " in statement
    and " meta l4proto icmpv6 counter " not in statement
    for statement in relation_nft_statements
):
    raise AssertionError(
        "CLAB emitted bare icmpv6 as an nftables expression instead of a "
        "protocol match"
    )
if sum(
    " meta l4proto icmp counter " in statement
    for statement in relation_nft_statements
) != 2:
    raise AssertionError("IPv4 relation rules do not carry the exact ICMP protocol match")
if sum(
    " meta l4proto icmpv6 counter " in statement
    for statement in relation_nft_statements
) != 2:
    raise AssertionError(
        "IPv6 relation rules do not carry the exact ICMPv6 protocol match"
    )

try:
    rules_for_cpm_rule(
        {
            "fromInterface": "source",
            "toInterface": "destination",
            "family": 4,
            "matches": [{"family": "any", "proto": "icmpv6"}],
            "action": "accept",
        }
    )
except ValueError:
    pass
else:
    raise AssertionError("renderer accepted an IPv6 ICMP match for an IPv4 rule")

with Path(os.environ["NFT_BATCH"]).open("w", encoding="utf-8") as handle:
    handle.write("add table inet fw\n")
    handle.write("add chain inet fw forward\n")
    for statement in relation_nft_statements:
        handle.write(f"{statement}\n")


def interface_for_runtime(runtime_name: str):
    matches = [
        (logical, iface)
        for logical, iface in interfaces.items()
        if iface.get("runtimeIfName") == runtime_name
    ]
    if len(matches) != 1:
        raise AssertionError("CPM runtime interface identity is not unique")
    return matches[0]


def cpm_route_for(selector):
    _, policy_iface = interface_for_runtime(selector["policyInterface"])
    family = "ipv4" if selector["family"] == 4 else "ipv6"
    matches = [
        route
        for route in policy_iface["routes"][family]
        if route.get("relationId") == relation_id
        and route.get("intent", {}).get("direction") == selector["direction"]
        and route.get("dst") == selector["destinationPrefix"]
    ]
    if len(matches) != 1:
        raise AssertionError("CPM selector does not have exactly one bounded route")
    return matches[0]


def expected_rule(selector):
    ip_cmd = "ip" if selector["family"] == 4 else "ip -6"
    source = str(ipaddress.ip_network(selector["sourcePrefix"], strict=False))
    destination = str(ipaddress.ip_network(selector["destinationPrefix"], strict=False))
    return (
        f"{ip_cmd} rule add from {source} "
        f"to {destination} "
        f'iif {selector["incomingInterface"]} '
        f'priority {selector["priority"]} table {selector["tableId"]}'
    )


def expected_route(selector):
    route = cpm_route_for(selector)
    ip_cmd = "ip" if selector["family"] == 4 else "ip -6"
    via_field = "via4" if selector["family"] == 4 else "via6"
    destination = str(ipaddress.ip_network(selector["destinationPrefix"], strict=False))
    return (
        f'{ip_cmd} route replace table {selector["tableId"]} '
        f"{destination} via {route[via_field]} "
        f'dev {selector["policyInterface"]} onlink'
    )


if len(selectors) != 4:
    raise AssertionError(f"expected four CPM selectors, got {len(selectors)}")
if any(selector["destinationPrefix"] in {"0.0.0.0/0", "::/0"} for selector in selectors):
    raise AssertionError("lateral relation unexpectedly grants default authority")

rules_present = sum(expected_rule(selector) in commands for selector in selectors)
routes_present = sum(expected_route(selector) in commands for selector in selectors)

if rules_present != 4 or routes_present != 4:
    raise AssertionError(
        "CLAB did not materialize the complete CPM relation selector contract: "
        f"selectors={len(selectors)} rules={rules_present} routes={routes_present}"
    )


contract_node = {
    "interfaces": copy.deepcopy(interfaces),
    "routeSelectionRules": copy.deepcopy(selectors),
}
contract_eth_map = {
    logical: iface["runtimeIfName"]
    for logical, iface in interfaces.items()
}
if len(render_relation_selection_rules(contract_node, contract_eth_map)) != 4:
    raise AssertionError("focused selector renderer did not emit four exact rules")


def expect_rejected(label, mutate):
    seeded = copy.deepcopy(contract_node)
    mutate(seeded)
    try:
        render_relation_selection_rules(seeded, contract_eth_map)
    except ValueError:
        return
    raise AssertionError(f"seeded negative was accepted: {label}")


expect_rejected(
    "wrong policy table",
    lambda seeded: seeded["routeSelectionRules"][0].__setitem__(
        "tableId", seeded["routeSelectionRules"][0]["tableId"] + 100
    ),
)
expect_rejected(
    "missing ingress identity",
    lambda seeded: seeded["routeSelectionRules"][0].pop("incomingInterface"),
)
expect_rejected(
    "missing return selector",
    lambda seeded: seeded.__setitem__(
        "routeSelectionRules",
        [
            selector
            for selector in seeded["routeSelectionRules"]
            if selector["direction"] != "return"
        ],
    ),
)


def remove_policy_route(seeded):
    selector = seeded["routeSelectionRules"][0]
    family = "ipv4" if selector["family"] == 4 else "ipv6"
    _, policy_iface = interface_for_runtime(selector["policyInterface"])
    policy_logical = next(
        logical
        for logical, iface in interfaces.items()
        if iface is policy_iface
    )
    routes = seeded["interfaces"][policy_logical]["routes"][family]
    seeded["interfaces"][policy_logical]["routes"][family] = [
        route
        for route in routes
        if not (
            route.get("relationId") == selector["relationId"]
            and route.get("intent", {}).get("direction") == selector["direction"]
        )
    ]


expect_rejected("missing bounded policy route", remove_policy_route)
expect_rejected(
    "transitive default destination",
    lambda seeded: seeded["routeSelectionRules"][0].__setitem__(
        "destinationPrefix", "0.0.0.0/0"
    ),
)

print(
    "PASS FS-270-HDS-010-SDS-010-SMS-020: CLAB materializes exact "
    "dual-stack policy-state selectors and bounded routes"
)
PY

nix shell --inputs-from "${repo_root}" nixpkgs#nftables nixpkgs#util-linux --command \
  unshare -Urn nft -c -f "${tmp_dir}/fs270-policy.nft"
