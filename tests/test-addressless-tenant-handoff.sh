#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import InterfaceModel, NodeModel, SiteModel
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

print("PASS addressless-tenant-handoff")
PY
