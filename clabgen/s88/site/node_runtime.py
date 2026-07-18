from __future__ import annotations

import copy
import hashlib
import json
import shlex
from typing import Dict, Any, List

from clabgen.models import NodeModel
from clabgen.s88.CM.access_advertisements import protected_reservation_source
from clabgen.s88.EM.base import render as render_em

EXEC_BUNDLE_SIZE = 100
INTERNAL_SELECTOR_RELATION_AUDIT_KEY = "_clabgen.selector.interface.relation.audit"

SELECTOR_RELATION_AUDIT_FILE_LABEL = "clab.selector.interface.relation.audit.file"
SELECTOR_RELATION_AUDIT_SHA256_LABEL = "clab.selector.interface.relation.audit.sha256"
SELECTOR_RELATION_AUDIT_INTERFACE_COUNT_LABEL = (
    "clab.selector.interface.relation.audit.interface.count"
)
SELECTOR_RELATION_AUDIT_RECORD_COUNT_LABEL = (
    "clab.selector.interface.relation.audit.record.count"
)


def selector_relation_audit_sidecar_path(topology_out: Any) -> Any:
    return topology_out.with_name(
        f"{topology_out.stem}.selector-interface-relation-audit.json"
    )


def _canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _selector_relation_record_count(audit: Dict[str, Any]) -> int:
    total = 0
    for records in audit.values():
        if isinstance(records, list):
            total += len(records)
    return total


def collect_selector_relation_audit_sidecar(
    topology_doc: Dict[str, Any],
    *,
    sidecar_name: str,
) -> Dict[str, Any]:
    topology = topology_doc.get("topology")
    nodes = topology.get("nodes") if isinstance(topology, dict) else None
    if not isinstance(nodes, dict):
        return {}

    sidecar_nodes: Dict[str, Any] = {}
    for node_name, node_def in sorted(nodes.items()):
        if not isinstance(node_def, dict):
            continue

        audit = node_def.pop(INTERNAL_SELECTOR_RELATION_AUDIT_KEY, None)
        if not audit:
            continue
        if not isinstance(audit, dict):
            raise ValueError(
                f"selector relation audit for node {node_name!r} must be an object"
            )

        canonical = _canonical_json(audit)
        digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        record_count = _selector_relation_record_count(audit)

        labels = node_def.setdefault("labels", {})
        if not isinstance(labels, dict):
            raise ValueError(f"node {node_name!r} labels must be an object")
        labels[SELECTOR_RELATION_AUDIT_FILE_LABEL] = sidecar_name
        labels[SELECTOR_RELATION_AUDIT_SHA256_LABEL] = digest
        labels[SELECTOR_RELATION_AUDIT_INTERFACE_COUNT_LABEL] = str(len(audit))
        labels[SELECTOR_RELATION_AUDIT_RECORD_COUNT_LABEL] = str(record_count)

        sidecar_nodes[str(node_name)] = {
            "sha256": digest,
            "interfaceCount": len(audit),
            "recordCount": record_count,
            "relations": audit,
        }

    if not sidecar_nodes:
        return {}

    return {
        "schemaVersion": 1,
        "kind": "containerlab-selector-interface-relation-audit",
        "nodes": sidecar_nodes,
    }


def _routing_mode(node: NodeModel) -> str:
    value = getattr(node, "routing_mode", None)
    if not isinstance(value, str) or not value:
        raise ValueError(f"node {node.name!r} missing explicit routing_mode")
    value = value.strip().lower()
    if value not in {"static", "bgp"}:
        raise ValueError(f"node {node.name!r} has invalid routing_mode {value!r}")
    return value


def build_node_data(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, str],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode(node)

    node_data: Dict[str, Any] = {
        "name": node_name,
        "role": node.role,
        "routing_mode": routing_mode,
        "interfaces": {},
        "route_intents": list(node.route_intents),
        "services": copy.deepcopy(node.services),
        "advertisements": copy.deepcopy(node.advertisements),
        "egressIntent": copy.deepcopy(node.egress_intent),
        "natIntent": copy.deepcopy(node.nat_intent),
        "forwardingIntent": copy.deepcopy(node.forwarding_intent),
        "runtimeOriginEgress": copy.deepcopy(node.runtime_origin_egress),
        "routeSelectionRules": copy.deepcopy(node.route_selection_rules),
        "loopback": {
            "ipv4": node.loopback4,
            "ipv6": node.loopback6,
        },
    }

    interfaces: Dict[str, Any] = {}
    for ifname, iface in sorted(node.interfaces.items()):
        if ifname not in eth_map:
            continue
        interfaces[ifname] = {
            "addr4": iface.addr4,
            "addr6": iface.addr6,
            "ll6": iface.ll6,
            "runtimeIfName": iface.runtime_if_name,
            "backingRef": copy.deepcopy(iface.backing_ref),
            "kind": iface.kind,
            "hostUplink": copy.deepcopy(iface.host_uplink),
            "tenant": iface.tenant,
            "overlay": iface.overlay,
            "upstream": iface.upstream,
            "lane": copy.deepcopy(iface.lane),
            "uplinks": list(getattr(iface, "uplinks", []) or []),
            "policyRoutingAllocation": copy.deepcopy(
                iface.policy_routing_allocation
            ),
            "dnsResolver": copy.deepcopy(iface.dns_resolver),
            "routes": iface.routes,
        }
    node_data["interfaces"] = interfaces

    if extra:
        node_data.update(copy.deepcopy(extra))

    return node_data


def _protected_reservation_binds(node: NodeModel) -> List[str]:
    advertisements = node.advertisements
    if not isinstance(advertisements, dict):
        return []
    source_files: set[str] = set()
    for advertisement_name, family in (("dhcp4", "ipv4"), ("dhcpv6", "ipv6")):
        scopes = advertisements.get(advertisement_name, [])
        if not isinstance(scopes, list):
            continue
        for scope in scopes:
            if not isinstance(scope, dict) or scope.get("enabled") is not True:
                continue
            source_file = protected_reservation_source(scope, family)
            if source_file is not None:
                source_files.add(source_file)
    return [f"{path}:{path}:ro" for path in sorted(source_files)]


def _has_unbound_runtime(node: NodeModel) -> bool:
    services = node.services
    if not isinstance(services, dict):
        return False
    dns = services.get("dns")
    if not isinstance(dns, dict):
        return False
    listen = dns.get("listen")
    if not isinstance(listen, list):
        return False
    return any(
        isinstance(value, str) and value not in {"127.0.0.1", "::1"}
        for value in listen
    )


def _selector_relation_audit(
    node: NodeModel, eth_map: Dict[str, str]
) -> Dict[str, List[Dict[str, Any]]]:
    runtime_names = set(eth_map.values())
    result: Dict[str, List[Dict[str, Any]]] = {}
    forwarding_intent = getattr(node, "forwarding_intent", {}) or {}
    rules = forwarding_intent.get("rules", [])
    if not isinstance(rules, list):
        return result

    for rule in rules:
        if not isinstance(rule, dict):
            continue
        relation_id = rule.get("relationId")
        relation_cardinality = rule.get("relationCardinality")
        cardinality_unit = (
            relation_cardinality.get("unit")
            if isinstance(relation_cardinality, dict)
            else None
        )
        if not (
            cardinality_unit == "selector-forwarding-rule"
        ):
            continue

        for side in ("from", "to"):
            endpoint = rule.get(side)
            if not isinstance(endpoint, dict):
                continue
            runtime_interface = endpoint.get("runtimeInterface")
            if (
                not isinstance(runtime_interface, str)
                or runtime_interface not in runtime_names
            ):
                continue
            result.setdefault(runtime_interface, []).append(
                {
                    "side": side,
                    "runtimeInterface": runtime_interface,
                    "nodeRole": node.role,
                    "relationId": relation_id,
                    "relationComment": rule.get("comment"),
                    "relationAction": rule.get("action"),
                    "relationDirection": rule.get("direction"),
                    "relationPurpose": endpoint.get("relationPurpose"),
                    "hostFacing": endpoint.get("hostFacing"),
                    "backingRef": copy.deepcopy(endpoint.get("backingRef")),
                    "lane": copy.deepcopy(endpoint.get("lane")),
                    "relationCardinality": copy.deepcopy(relation_cardinality),
                }
            )

    return result


def bundle_exec_commands(
    exec_cmds: List[str],
    *,
    bundle_size: int = EXEC_BUNDLE_SIZE,
) -> List[str]:
    commands = [str(cmd) for cmd in exec_cmds if str(cmd).strip()]
    if not commands:
        return []
    if bundle_size < 1:
        raise ValueError("exec bundle size must be positive")

    bundled: List[str] = []
    total = len(commands)
    for start in range(0, total, bundle_size):
        chunk = commands[start : start + bundle_size]
        end = start + len(chunk)
        bundle_number = (start // bundle_size) + 1
        script_lines = [
            "set -e",
            f"echo '[clab-node-init] commands {start + 1}-{end}/{total}' >&2",
            'clab_bundle_generation="$(awk \'{print $22}\' /proc/1/stat)"',
        ]
        if bundle_number > 1:
            previous_bundle = bundle_number - 1
            predecessor_marker = (
                "/tmp/clabgen-exec-bundle-${clab_bundle_generation}-"
                f"{previous_bundle}.ready"
            )
            script_lines.extend(
                [
                    "clab_predecessor_ready=0",
                    "for attempt in $(seq 1 600); do",
                    f"  if test -e {predecessor_marker}; then clab_predecessor_ready=1; break; fi",
                    "  sleep 0.1",
                    "done",
                    "[ \"$clab_predecessor_ready\" -eq 1 ] || { printf '%s\\n' 'CLAB predecessor bundle did not complete' >&2; exit 1; }",
                ]
            )
        script_lines.extend(chunk)
        script_lines.append(
            "touch /tmp/clabgen-exec-bundle-${clab_bundle_generation}-"
            f"{bundle_number}.ready"
        )
        bundled.append(f"sh -e -c {shlex.quote(chr(10).join(script_lines))}")
    return bundled


def render_linux_node(
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, str],
    extra: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    routing_mode = _routing_mode(node)
    node_data = build_node_data(node_name, node, eth_map, extra=extra)

    exec_cmds = render_em(
        node.role,
        node_name,
        node_data,
        eth_map,
        routing_mode=routing_mode,
        disable_dynamic=(routing_mode != "bgp"),
    )
    audit_map: Dict[str, str] = {}
    for logical, runtime in sorted(eth_map.items()):
        audit_map[runtime] = logical
    selector_relation_audit = _selector_relation_audit(node, eth_map)

    labels = {
        "clab.interface.map": json.dumps(eth_map, sort_keys=True),
        "clab.interface.audit": json.dumps(audit_map, sort_keys=True),
    }
    bundled_exec_cmds = bundle_exec_commands(exec_cmds)
    labels["clab.exec.command.count"] = str(len(exec_cmds))
    labels["clab.exec.bundle.count"] = str(len(bundled_exec_cmds))
    labels["clab.exec.bundle.size"] = str(EXEC_BUNDLE_SIZE)

    rendered = {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "labels": labels,
        "network-mode": "none",
        "restart-policy": "no",
        "cmd": "/bin/sh -c 'sleep infinity'",
        "exec": bundled_exec_cmds,
    }
    protected_binds = _protected_reservation_binds(node)
    if protected_binds:
        rendered["binds"] = protected_binds
        labels["clab.access-advertisements.runtime"] = "kea"
    if _has_unbound_runtime(node):
        labels["clab.dns.runtime"] = "unbound"
    if selector_relation_audit:
        rendered[INTERNAL_SELECTOR_RELATION_AUDIT_KEY] = selector_relation_audit
    return rendered
