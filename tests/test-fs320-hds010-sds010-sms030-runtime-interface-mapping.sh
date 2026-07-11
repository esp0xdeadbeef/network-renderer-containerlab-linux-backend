#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-030
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import json

from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.site.node_runtime import (
    INTERNAL_SELECTOR_RELATION_AUDIT_KEY,
    SELECTOR_RELATION_AUDIT_FILE_LABEL,
    SELECTOR_RELATION_AUDIT_INTERFACE_COUNT_LABEL,
    SELECTOR_RELATION_AUDIT_RECORD_COUNT_LABEL,
    SELECTOR_RELATION_AUDIT_SHA256_LABEL,
    collect_selector_relation_audit_sidecar,
)
from clabgen.s88.EM.base import render as render_em
from clabgen.s88.site.eth_map import build_eth_maps
from clabgen.s88.site.node_runtime import build_node_data
from clabgen.s88.site.node_runtime import bundle_exec_commands
from clabgen.s88.site.node_runtime import render_linux_node
from clabgen.s88.site.topology import render_site_topology


def node(interfaces):
    return NodeModel(
        name="router",
        role="core",
        routing_domain="test",
        interfaces=interfaces,
        routing_mode="static",
    )


def site_for(interfaces, endpoints, bridge="br-test-sms030"):
    return SiteModel(
        enterprise="test",
        site="clab",
        nodes={"router": node(interfaces)},
        links={
            "l0": LinkModel(
                name="l0",
                kind="p2p",
                endpoints=endpoints,
                bridge=bridge,
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
            "relationId": "selector-handoff-forward--router--selector-transport-to-access-to-selector--fabric",
            "comment": "selector-handoff-forward--router--selector-transport-to-access-to-selector--fabric",
            "direction": "forward",
            "relationCardinality": {
                "unit": "selector-forwarding-rule",
                "decomposition": "one-rule-per-selector-handoff-direction",
            },
            "from": {
                "runtimeInterface": "lan-target0",
                "relationPurpose": "selector-transport",
                "hostFacing": False,
                "backingRef": {
                    "kind": "attachment",
                    "name": "inside-tenant",
                },
                "lane": {
                    "kind": "tenant",
                    "access": "access-client",
                },
            },
            "to": {
                "runtimeInterface": "wan-target0",
                "relationPurpose": "access-to-selector",
                "hostFacing": False,
                "backingRef": {
                    "kind": "link",
                    "name": "p2p-access-client-downstream-selector",
                },
                "lane": {
                    "kind": "access-edge",
                    "access": "access-client",
                },
            },
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

cm_rendered = render_linux_node(
    node_name="router",
    node=cm_node,
    eth_map={"inside": "lan-target0", "outside": "wan-target0"},
)
cm_labels = cm_rendered.get("labels", {})
if "clab.selector.interface.relation.audit" in cm_labels:
    raise AssertionError(
        "selector-relation-audit-env-boundary: full audit must not be emitted "
        "as a Containerlab label because labels are injected as CLAB_LABEL_* env"
    )
selector_audit = cm_rendered.get(INTERNAL_SELECTOR_RELATION_AUDIT_KEY, {})
wan_audit = selector_audit.get("wan-target0", [])
if len(wan_audit) != 1:
    raise AssertionError(f"selector-relation-audit-cardinality: unexpected audit {selector_audit!r}")
wan_record = wan_audit[0]
if wan_record.get("relationId") != "selector-handoff-forward--router--selector-transport-to-access-to-selector--fabric":
    raise AssertionError(f"selector-relation-audit-id: unexpected record {wan_record!r}")
if wan_record.get("relationPurpose") != "access-to-selector":
    raise AssertionError(f"selector-relation-audit-purpose: unexpected record {wan_record!r}")
if wan_record.get("hostFacing") is not False:
    raise AssertionError(f"selector-relation-audit-host-facing: unexpected record {wan_record!r}")
if wan_record.get("nodeRole") != "core":
    raise AssertionError(f"selector-relation-audit-role: unexpected record {wan_record!r}")
if wan_record.get("backingRef", {}).get("name") != "p2p-access-client-downstream-selector":
    raise AssertionError(f"selector-relation-audit-backing-ref: unexpected record {wan_record!r}")

topology_doc = {"topology": {"nodes": {"router": dict(cm_rendered)}}}
sidecar = collect_selector_relation_audit_sidecar(
    topology_doc,
    sidecar_name="fabric.clab.selector-interface-relation-audit.json",
)
sidecar_labels = topology_doc["topology"]["nodes"]["router"].get("labels", {})
if INTERNAL_SELECTOR_RELATION_AUDIT_KEY in topology_doc["topology"]["nodes"]["router"]:
    raise AssertionError("selector-relation-audit-strip: internal audit leaked into topology node")
if sidecar_labels.get(SELECTOR_RELATION_AUDIT_FILE_LABEL) != "fabric.clab.selector-interface-relation-audit.json":
    raise AssertionError(f"selector-relation-audit-sidecar-file-label: unexpected labels {sidecar_labels!r}")
if sidecar_labels.get(SELECTOR_RELATION_AUDIT_INTERFACE_COUNT_LABEL) != "2":
    raise AssertionError(f"selector-relation-audit-interface-count-label: unexpected labels {sidecar_labels!r}")
if sidecar_labels.get(SELECTOR_RELATION_AUDIT_RECORD_COUNT_LABEL) != "2":
    raise AssertionError(f"selector-relation-audit-record-count-label: unexpected labels {sidecar_labels!r}")
if len(sidecar_labels.get(SELECTOR_RELATION_AUDIT_SHA256_LABEL, "")) != 64:
    raise AssertionError(f"selector-relation-audit-sha-label: unexpected labels {sidecar_labels!r}")
sidecar_node = sidecar.get("nodes", {}).get("router", {})
if sidecar_node.get("relations", {}).get("wan-target0", [{}])[0].get("relationPurpose") != "access-to-selector":
    raise AssertionError(f"selector-relation-audit-sidecar-content: unexpected sidecar {sidecar!r}")

many_cmds = [f"echo command-{idx}" for idx in range(205)]
bundled = bundle_exec_commands(many_cmds, bundle_size=100)
if len(bundled) != 3:
    raise AssertionError(f"exec-bundling-count: expected 3 bundles, got {len(bundled)}")
if "command-0" not in bundled[0] or "command-204" not in bundled[-1]:
    raise AssertionError(f"exec-bundling-content: commands were not preserved: {bundled!r}")
if len(cm_rendered.get("exec", [])) >= len(render_em("core", "router", cm_node_data, {"inside": "lan-target0", "outside": "wan-target0"})):
    raise AssertionError(f"exec-bundling-rendered: rendered node did not reduce Containerlab exec fan-out: {cm_rendered!r}")
for label in ("clab.exec.command.count", "clab.exec.bundle.count", "clab.exec.bundle.size"):
    if label not in cm_labels:
        raise AssertionError(f"exec-bundling-audit-label: missing {label}: {cm_labels!r}")

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

# FC2/SN2: empty runtimeIfName
empty_runtime = site_for(
    {
        "wan": InterfaceModel(name="wan", runtime_if_name=""),
    },
    {"router": {"interface": "wan"}},
)

assert_refuses(
    "empty-runtime-if-name",
    lambda: build_eth_maps(empty_runtime),
    "missing CPM runtimeIfName",
)
assert_refuses(
    "empty-runtime-if-name-output-gate",
    lambda: render_site_topology(empty_runtime),
    "missing CPM runtimeIfName",
)

# SN2 recovery: non-empty runtimeIfName after empty
recovered_runtime = site_for(
    {
        "wan": InterfaceModel(name="wan", runtime_if_name="wan-recovered"),
    },
    {"router": {"interface": "wan"}},
)
recovered_maps = build_eth_maps(recovered_runtime)
if recovered_maps["router"]["wan"] != "wan-recovered":
    raise AssertionError(f"recovery-after-empty: unexpected eth map {recovered_maps!r}")

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
            bridge="br-dup-0",
        ),
        "l1": LinkModel(
            name="l1",
            kind="p2p",
            endpoints={"router": {"interface": "right"}},
            bridge="br-dup-1",
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
