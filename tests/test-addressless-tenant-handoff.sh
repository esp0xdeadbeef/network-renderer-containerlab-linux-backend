#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import InterfaceModel, NodeModel, SiteModel
from clabgen.s88.enterprise.merge import merge_sites
from clabgen.s88.site.topology import render_site_topology


def node(name, role):
    return NodeModel(
        name=name,
        role=role,
        routing_domain="test",
        interfaces={
            "tenant-iot": InterfaceModel(
                name="tenant-iot",
                kind="tenant",
                tenant="iot",
                runtime_if_name="eth1",
            )
        },
        routing_mode="static",
    )


site = SiteModel(
    enterprise="test",
    site="clab",
    nodes={
        "access-iot": node("access-iot", "access"),
        "core-nebula": node("core-nebula", "core"),
    },
    links={},
    single_access="client",
    domains={},
)

rendered = render_site_topology(site)
links = rendered["topology"]["links"]
matching = [
    link
    for link in links
    if sorted(link.get("endpoints", [])) == ["access-iot:eth1", "core-nebula:eth1"]
]
if len(matching) != 1:
    raise AssertionError(f"expected one addressless tenant handoff link, got {links!r}")
bridge = matching[0].get("labels", {}).get("clab.link.bridge", "")
if not bridge:
    raise AssertionError(f"addressless tenant handoff link did not get a bridge: {matching[0]!r}")

site.nodes["core-nebula"].interfaces["tenant-iot"].tenant = None
try:
    render_site_topology(site)
except ValueError as exc:
    if "no usable prefix" not in str(exc):
        raise AssertionError(f"unexpected refusal: {exc!r}")
else:
    raise AssertionError("addressless tenant handoff without explicit tenant must fail closed")

site.nodes["core-nebula"].interfaces["tenant-iot"].tenant = "iot"
site.nodes["wireguard-host128"] = node("wireguard-host128", "core")
site.nodes["wireguard-remote-egress"] = node("wireguard-remote-egress", "core")
rendered = render_site_topology(site)
links = rendered["topology"]["links"]
nodes = rendered["topology"]["nodes"]
oversized = [
    link
    for link in links
    if len(link.get("endpoints", [])) > 2
]
if oversized:
    raise AssertionError(f"containerlab links must stay binary: {oversized!r}")
multi_links = [
    link
    for link in links
    if any(str(ep).endswith(":eth1") for ep in link.get("endpoints", []))
]
if len(multi_links) != 4:
    raise AssertionError(f"expected four binary tenant bridge links, got {multi_links!r}")
bridge_endpoints = {
    str(endpoint).split(":", 1)[0]
    for link in multi_links
    for endpoint in link.get("endpoints", [])
    if isinstance(endpoint, str) and endpoint.startswith("br-")
}
if not bridge_endpoints:
    raise AssertionError(f"expected binary fanout to use bridge endpoints: {multi_links!r}")
for bridge_node in bridge_endpoints:
    if nodes.get(bridge_node, {}).get("kind") != "bridge":
        raise AssertionError(f"missing bridge-kind node for {bridge_node!r}: {nodes!r}")

merged = merge_sites({"test.clab": site})
merged_nodes = merged["topology"]["nodes"]
for bridge_node in bridge_endpoints:
    if merged_nodes.get(bridge_node, {}).get("kind") != "bridge":
        raise AssertionError(
            f"enterprise merge must preserve bridge-kind node {bridge_node!r}: {merged_nodes!r}"
        )

print("PASS addressless-tenant-handoff")
PY
