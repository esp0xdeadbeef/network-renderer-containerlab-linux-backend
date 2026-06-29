from __future__ import annotations

import copy
import json
from typing import Dict, Any, List

from clabgen.models import NodeModel
from clabgen.s88.EM.base import render as render_em


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
            "kind": iface.kind,
            "hostUplink": copy.deepcopy(iface.host_uplink),
            "tenant": iface.tenant,
            "overlay": iface.overlay,
            "upstream": iface.upstream,
            "lane": copy.deepcopy(iface.lane),
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
    if selector_relation_audit:
        labels["clab.selector.interface.relation.audit"] = json.dumps(
            selector_relation_audit, sort_keys=True
        )

    return {
        "kind": "linux",
        "image": "clab-frr-plus-tooling:latest",
        "labels": labels,
        "network-mode": "none",
        "restart-policy": "no",
        "cmd": "/bin/sh -c 'sleep infinity'",
        "exec": exec_cmds,
    }
