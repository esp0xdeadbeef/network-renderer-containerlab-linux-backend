#!/usr/bin/env bash
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-002
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-004
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-005
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-002
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-004
# GAMP-ID: USR-MODEL-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-005
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.site.eth_map import build_eth_maps
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
