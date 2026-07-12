#!/usr/bin/env bash
# GAMP-ID: FS-500-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
# Construction test: CLAB link co-location for selector fabric p2p links.
# Proves SMS predicates MR1, MR4, MR5, MR6, FC1-FC5, SN1, SN2.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - "${repo_root}" <<'PY'
import sys
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.site.topology import render_site_topology

repo_root = sys.argv[1]
trace = "FS-500-HDS-010-SDS-010-SMS-050"

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

def base_site(links, nodes=None):
    if nodes is None:
        nodes = {
            "alpha": router("alpha", "p2p-alpha", "p2p-a"),
            "beta": router("beta", "p2p-beta", "p2p-b"),
        }
    return SiteModel(
        enterprise="test",
        site="site-a",
        nodes=nodes,
        links=links,
        single_access="client",
        domains={},
    )

# --- Positive case: both endpoints share the same CLAB link ---
positive_site = base_site({
    "p2p-link": LinkModel(
        name="p2p-alpha-beta",
        kind="p2p",
        bridge="br-p2p-alpha-beta",
        endpoints={
            "alpha": {"interface": "p2p-alpha"},
            "beta": {"interface": "p2p-beta"},
        },
    )
})
rendered = render_site_topology(positive_site)
links = rendered["topology"]["links"]
assert len(links) == 1, f"expected 1 link, got {len(links)}: {links}"
link = links[0]

# MR4: both endpoints of the modeled p2p link appear in the same CLAB link
endpoints = sorted(link.get("endpoints", []))
expected_endpoints = sorted(["alpha:p2p-a", "beta:p2p-b"])
assert endpoints == expected_endpoints, \
    f"endpoint mismatch: got {endpoints}, expected {expected_endpoints}"

# Both endpoints share the same bridge
bridge_label = link.get("labels", {}).get("clab.link.bridge")
assert bridge_label and bridge_label.startswith("br-"), \
    f"bridge label missing or malformed: {bridge_label}"

# Source link identity preserved
source_link = link.get("labels", {}).get("clab.source.link")
assert source_link in ("p2p-alpha-beta", "p2p-link"), \
    f"source link identity mismatch: got {source_link}"

# --- Negative case 1: split link ---
# Two separate links that should NOT be connected
split_site = base_site({
    "p2p-link-alpha": LinkModel(
        name="p2p-alpha-side",
        kind="p2p",
        bridge="br-alpha-side",
        endpoints={
            "alpha": {"interface": "p2p-alpha"},
        },
    ),
    "p2p-link-beta": LinkModel(
        name="p2p-beta-side",
        kind="p2p",
        bridge="br-beta-side",
        endpoints={
            "beta": {"interface": "p2p-beta"},
        },
    ),
})
rendered_split = render_site_topology(split_site)
split_links = rendered_split["topology"]["links"]
assert len(split_links) == 2, \
    f"split case: expected 2 separate links, got {len(split_links)}: {split_links}"

# Each link has the modeled endpoint (host veth is added automatically)
for sl in split_links:
    eps = sl.get("endpoints", [])
    node_eps = [e for e in eps if not e.startswith("host:")]
    assert len(node_eps) == 1, \
        f"split link should have 1 modeled endpoint, got {len(node_eps)} node endpoints from {eps}"

# The two links have different bridges (may be hashed)
bridge_labels = [sl.get("labels", {}).get("clab.link.bridge") for sl in split_links]
assert all(bl and bl.startswith("br-") for bl in bridge_labels), \
    f"bridge labels malformed: {bridge_labels}"
assert bridge_labels[0] != bridge_labels[1], \
    f"split bridges should differ: {bridge_labels}"

# --- Negative: name-derived repair ---
# Different link names, different bridges, should NOT co-locate
name_derived_site = base_site({
    "p2p-link-real": LinkModel(
        name="p2p-link-real",
        kind="p2p",
        bridge="br-real-bridge",
        endpoints={
            "alpha": {"interface": "p2p-alpha"},
        },
    ),
    "p2p-link-impostor": LinkModel(
        name="p2p-link-real-impostor",
        kind="p2p",
        bridge="br-impostor-bridge",
        endpoints={
            "beta": {"interface": "p2p-beta"},
        },
    ),
})
rendered_name = render_site_topology(name_derived_site)
name_links = rendered_name["topology"]["links"]
# The bridges differ despite similar names
name_bridges = [nl.get("labels", {}).get("clab.link.bridge") for nl in name_links]
assert name_bridges[0] != name_bridges[1], \
    f"name-derived bridges must differ: {name_bridges}"

print(f"PASS {trace} CLAB link co-location")
PY
