from __future__ import annotations

from typing import Dict

from clabgen.models import SiteModel, NodeModel
from clabgen.s88.site.interface_tags import interface_tag_values
from clabgen.s88.site.policy_interface_tags import build_policy_interface_tags
from clabgen.s88.site.policy_contract import (
    contract_external_names,
    contract_tenant_names,
    service_tenants,
)
from clabgen.s88.site.policy_rules import build_policy_rules


def build_policy_firewall_state(
    site: SiteModel, policy_node_name: str, eth_map: Dict[str, str]
):
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
    if node.role == "policy":
        return {
            "policy_firewall_state": build_policy_firewall_state(
                site,
                node_name,
                eth_map,
            )
        }
    return {}
