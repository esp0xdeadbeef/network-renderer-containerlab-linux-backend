#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-030
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.EM.base import render as render_em
from clabgen.s88.site.eth_map import build_eth_maps
from clabgen.s88.site.node_runtime import build_node_data
from clabgen.s88.site.topology import render_site_topology


def node(interfaces):
    return NodeModel(
        name="router",
        role="core",
        routing_domain="test",
        interfaces=interfaces,
        routing_mode="static",
    )


def site_for(interfaces, endpoints):
    return SiteModel(
        enterprise="test",
        site="clab",
        nodes={"router": node(interfaces)},
        links={
            "l0": LinkModel(
                name="l0",
                kind="p2p",
                endpoints=endpoints,
            )
        },
        single_access="client",
        domains={},
    )


def assert_refuses(label, fn, expected):
    try:
        fn()
    except ValueError as exc:
        text = str(exc)
        if expected not in text:
            raise AssertionError(
                f"{label}: expected {expected!r} in diagnostic, got {text!r}"
            )
        return
    raise AssertionError(f"{label}: expected ValueError")


valid_runtime = site_for(
    {
        "wan": InterfaceModel(name="wan", runtime_if_name="wan-target0"),
    },
    {"router": {"interface": "wan"}},
)

eth_maps = build_eth_maps(valid_runtime)
if eth_maps["router"]["wan"] != "wan-target0":
    raise AssertionError(f"valid-runtime-if-name: unexpected eth map {eth_maps!r}")

topology = render_site_topology(valid_runtime)
if "router:wan-target0" not in str(topology):
    raise AssertionError(f"valid-runtime-if-name-output: topology did not use CPM runtimeIfName: {topology!r}")
node_labels = topology["topology"]["nodes"]["router"].get("labels", {})
if node_labels.get("clab.interface.map") != '{"wan": "wan-target0"}':
    raise AssertionError(f"audit-map-forward: missing logical-to-runtime label: {node_labels!r}")
if node_labels.get("clab.interface.audit") != '{"wan-target0": "wan"}':
    raise AssertionError(f"audit-map-reverse: missing runtime-to-logical label: {node_labels!r}")

cm_node = node(
    {
        "inside": InterfaceModel(name="inside", runtime_if_name="lan-target0"),
        "outside": InterfaceModel(name="outside", runtime_if_name="wan-target0"),
    }
)
cm_node.forwarding_intent = {
    "uplinkInterfaces": ["outside"],
    "rules": [
        {
            "fromInterface": "inside",
            "toInterface": "outside",
            "action": "accept",
        }
    ],
}
cm_node.nat_intent = {
    "enabled": True,
    "families": {"ipv4": True},
    "wanInterfaces": ["outside"],
    "masqueradeInterfaces": ["outside"],
    "masqueradeSourcePrefixes4": ["10.0.0.0/24"],
}
cm_node_data = build_node_data(
    "router",
    cm_node,
    {"inside": "lan-target0", "outside": "wan-target0"},
)
cm_exec = "\n".join(
    render_em("core", "router", cm_node_data, {"inside": "lan-target0", "outside": "wan-target0"})
)
for expected in ('iifname "lan-target0"', 'oifname "wan-target0"', 'oifname "wan-target0" masquerade'):
    if expected not in cm_exec:
        raise AssertionError(f"cm-runtime-if-name: missing {expected!r} in {cm_exec}")
for forbidden in ('iifname "inside"', 'oifname "outside"', 'oifname "outside" masquerade'):
    if forbidden in cm_exec:
        raise AssertionError(f"cm-runtime-if-name: leaked logical interface {forbidden!r} in {cm_exec}")

cm_bad_data = build_node_data("router", cm_node, {"inside": "lan-target0"})
assert_refuses(
    "cm-missing-runtime-if-name",
    lambda: render_em("core", "router", cm_bad_data, {"inside": "lan-target0"}),
    "without explicit CPM runtimeIfName",
)


missing_runtime = site_for(
    {
        "wan": InterfaceModel(name="wan"),
    },
    {"router": {"interface": "wan"}},
)

assert_refuses(
    "missing-runtime-if-name",
    lambda: build_eth_maps(missing_runtime),
    "missing CPM runtimeIfName",
)
assert_refuses(
    "missing-runtime-if-name-output-gate",
    lambda: render_site_topology(missing_runtime),
    "missing CPM runtimeIfName",
)

duplicate_runtime = SiteModel(
    enterprise="test",
    site="clab",
    nodes={
        "router": node(
            {
                "left": InterfaceModel(name="left", runtime_if_name="dup0"),
                "right": InterfaceModel(name="right", runtime_if_name="dup0"),
            }
        )
    },
    links={
        "l0": LinkModel(
            name="l0",
            kind="p2p",
            endpoints={"router": {"interface": "left"}},
        ),
        "l1": LinkModel(
            name="l1",
            kind="p2p",
            endpoints={"router": {"interface": "right"}},
        ),
    },
    single_access="client",
    domains={},
)

assert_refuses(
    "duplicate-runtime-if-name",
    lambda: build_eth_maps(duplicate_runtime),
    "maps both",
)
assert_refuses(
    "duplicate-runtime-if-name-output-gate",
    lambda: render_site_topology(duplicate_runtime),
    "maps both",
)

print("PASS runtime-interface-mapping-refusals")
PY
