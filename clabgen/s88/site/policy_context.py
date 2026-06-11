from __future__ import annotations

from typing import Dict

from clabgen.models import SiteModel, NodeModel
from clabgen.s88.EM.interface_names import require_runtime_name
from clabgen.s88.site.interface_tags import interface_tag_values
from clabgen.s88.site.policy_interface_tags import build_policy_interface_tags
from clabgen.s88.site.policy_contract import (
    contract_external_names,
    contract_tenant_names,
    service_tenants,
)
from clabgen.s88.site.policy_rules import build_policy_rules


def _interface_name_map(node: NodeModel, eth_map: Dict[str, str]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for logical_name, runtime_name in eth_map.items():
        if not isinstance(logical_name, str) or not logical_name:
            continue
        if not isinstance(runtime_name, str) or not runtime_name:
            continue
        result[logical_name] = runtime_name
        result[runtime_name] = runtime_name

        iface = node.interfaces.get(logical_name)
        iface_runtime_name = getattr(iface, "runtime_if_name", None)
        if isinstance(iface_runtime_name, str) and iface_runtime_name:
            result[iface_runtime_name] = runtime_name
    return result


def _forwarding_policy_rules(
    node: NodeModel,
    eth_map: Dict[str, str],
) -> list[Dict[str, object]]:
    forwarding_intent = node.forwarding_intent
    if not isinstance(forwarding_intent, dict):
        return []

    raw_rules = forwarding_intent.get("rules")
    if not isinstance(raw_rules, list):
        return []

    name_map = _interface_name_map(node, eth_map)
    rules: list[Dict[str, object]] = []
    for raw_rule in raw_rules:
        if not isinstance(raw_rule, dict):
            continue
        rule = dict(raw_rule)
        rule["fromInterface"] = require_runtime_name(
            raw_rule.get("fromInterface"),
            name_map,
            "forwardingIntent.rules.fromInterface",
        )
        rule["toInterface"] = require_runtime_name(
            raw_rule.get("toInterface"),
            name_map,
            "forwardingIntent.rules.toInterface",
        )
        rules.append(rule)
    return rules


def build_policy_firewall_state(
    site: SiteModel, policy_node_name: str, eth_map: Dict[str, str]
):
    policy_node = site.nodes.get(policy_node_name)
    if policy_node is None:
        raise RuntimeError(f"policy node {policy_node_name!r} is missing")

    contract = dict(site.raw_policy or {})
    resolved_service_tenants = service_tenants(site, contract)

    tenants = set(contract_tenant_names(contract))
    for values in resolved_service_tenants.values():
        tenants.update(values)
    externals = set(contract_external_names(contract))

    interface_tags = build_policy_interface_tags(
        site,
        policy_node_name,
        eth_map,
        tenants,
        externals,
    )

    rules = build_policy_rules(
        contract, interface_tag_values(interface_tags), resolved_service_tenants
    )
    rules.extend(_forwarding_policy_rules(policy_node, eth_map))

    return {
        "interface_tags": interface_tags,
        "service_tenants": resolved_service_tenants,
        "rules": rules,
    }


def build_node_firewall_state(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, str],
):
    # Policy, downstream-selector, and upstream-selector nodes all need
    # policy_firewall_state wrapping for CPM firewall rule materialization.
    # The DS and US are selector nodes that forward traffic between access
    # and policy; they benefit from interface_tags for tenant-aware nft
    # rule generation and cpm_firewall_rules wrapping for deny-by-default
    # enforcement at the selector boundary.
    if node.role in {"policy", "downstream-selector", "upstream-selector"}:
        return {
            "policy_firewall_state": build_policy_firewall_state(
                site,
                node_name,
                eth_map,
            )
        }
    return {}
