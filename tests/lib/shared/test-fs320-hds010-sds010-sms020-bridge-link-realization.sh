#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-030
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.site.topology import render_site_topology


def router(name, iface_name, runtime_if_name):
    return NodeModel(
        name=name,
        role="core",
        routing_domain="test",
        interfaces={
            iface_name: InterfaceModel(
                name=iface_name,
                runtime_if_name=runtime_if_name,
            ),
        },
        routing_mode="static",
    )


def base_site(link):
    return SiteModel(
        enterprise="test",
        site="clab",
        nodes={
            "left": router("left", "uplink-left", "wan-left0"),
            "right": router("right", "uplink-right", "wan-right0"),
        },
        links={"actual-contract-link": link},
        single_access="client",
        domains={},
    )


def assert_refuses(label, site, expected):
    try:
        render_site_topology(site)
    except ValueError as exc:
        text = str(exc)
        if expected not in text:
            raise AssertionError(
                f"{label}: expected {expected!r} in diagnostic, got {text!r}"
            )
        return
    raise AssertionError(f"{label}: expected ValueError")


explicit = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        bridge="br-contract",
        endpoints={
            "left": {"interface": "uplink-left"},
            "right": {"interface": "uplink-right"},
        },
    )
)
rendered = render_site_topology(explicit)
links = rendered["topology"]["links"]
if len(links) != 1:
    raise AssertionError(f"expected exactly one explicit model link, got {links!r}")
link = links[0]
if sorted(link.get("endpoints", [])) != ["left:wan-left0", "right:wan-right0"]:
    raise AssertionError(f"link did not use explicit CPM runtimeIfName values: {link!r}")
if link.get("labels", {}).get("clab.link.bridge") != "br-contract":
    raise AssertionError(f"link did not use explicit bridge contract: {link!r}")
if link.get("labels", {}).get("clab.source.link") != "actual-contract-link":
    raise AssertionError(f"link did not preserve source contract reference: {link!r}")

missing_interface_field = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        endpoints={
            "left": {},
            "right": {"interface": "uplink-right"},
        },
    )
)
assert_refuses(
    "missing-link-endpoint-interface",
    missing_interface_field,
    "missing explicit interface",
)

unknown_interface = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        endpoints={
            "left": {"interface": "not-present-on-node"},
            "right": {"interface": "uplink-right"},
        },
    )
)
assert_refuses(
    "unknown-link-endpoint-interface",
    unknown_interface,
    "missing interface",
)

unknown_node = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        endpoints={
            "left": {"interface": "uplink-left"},
            "ghost": {"interface": "uplink-right"},
        },
    )
)
assert_refuses(
    "unknown-link-endpoint-node",
    unknown_node,
    "unknown node",
)

missing_bridge = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        endpoints={
            "left": {"interface": "uplink-left"},
            "right": {"interface": "uplink-right"},
        },
    )
)
assert_refuses(
    "missing-bridge-field",
    missing_bridge,
    "MISSING_CPM_BRIDGE_FIELD",
)

missing_bridge_recovered = base_site(
    LinkModel(
        name="actual-contract-link",
        kind="p2p",
        bridge="br-contract",
        endpoints={
            "left": {"interface": "uplink-left"},
            "right": {"interface": "uplink-right"},
        },
    )
)
rendered_recovered = render_site_topology(missing_bridge_recovered)
recovered_links = rendered_recovered["topology"]["links"]
if len(recovered_links) != 1:
    raise AssertionError(f"recovery: expected exactly one link, got {recovered_links!r}")
recovered_link = recovered_links[0]
if recovered_link.get("labels", {}).get("clab.link.bridge") != "br-contract":
    raise AssertionError(f"recovery: link did not use explicit bridge contract: {recovered_link!r}")

print("PASS bridge-link-realization-contracts")
PY
