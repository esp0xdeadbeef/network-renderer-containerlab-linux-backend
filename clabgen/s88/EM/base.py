from __future__ import annotations

from typing import Any, Dict, List

from .roles import (
    parse_access,
    parse_core,
    parse_downstream_selector,
    parse_policy,
    parse_upstream_selector,
    parse_wan_peer,
)

from .default import render as render_default


def _core_egress_masquerade(
    node_data: Dict[str, Any],
    role_cfg: Dict[str, Any],
    wan_if: str | None,
) -> Dict[str, Any]:
    wan_firewall_cfg = role_cfg.get("wan_firewall", {})
    if not isinstance(wan_firewall_cfg, dict):
        wan_firewall_cfg = {}

    masquerade = wan_firewall_cfg.get("masquerade")
    if isinstance(masquerade, dict) and masquerade:
        return dict(masquerade)

    nat_intent = node_data.get("natIntent", {})
    if isinstance(nat_intent, dict) and nat_intent.get("enabled") is True:
        if not isinstance(wan_if, str) or not wan_if:
            return {}
        families = nat_intent.get("families", {})
        families = families if isinstance(families, dict) else {}
        result: Dict[str, Any] = {
            "ipv4": bool(families.get("ipv4", False)),
            "ipv6": bool(families.get("ipv6", False)),
            "oifnames": [wan_if],
        }
        source6 = nat_intent.get("masqueradeSourcePrefixes6")
        if isinstance(source6, list) and source6:
            source6_prefixes: List[str] = []
            for source_prefix in source6:
                if isinstance(source_prefix, str) and source_prefix:
                    source6_prefixes.append(source_prefix)
            result["saddr6"] = source6_prefixes
        return result

    egress_intent = node_data.get("egressIntent", {})
    if not isinstance(egress_intent, dict):
        return {}
    if not bool(egress_intent.get("exit", False)):
        return {}
    if not isinstance(wan_if, str) or not wan_if:
        return {}

    wan_interfaces = egress_intent.get("wanInterfaces", [])
    if not isinstance(wan_interfaces, list) or not wan_interfaces:
        return {}

    return {
        "ipv4": True,
        "ipv6": True,
        "oifnames": [wan_if],
    }


def _parse(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> Dict[str, Any]:
    normalized_role = str(role or "").strip()

    if normalized_role == "access":
        return parse_access(node_name, node_data, eth_map)

    if normalized_role == "core":
        return parse_core(node_name, node_data, eth_map)

    if normalized_role == "policy":
        return parse_policy(node_name, node_data, eth_map)

    if normalized_role == "upstream-selector":
        return parse_upstream_selector(node_name, node_data, eth_map)

    if normalized_role == "downstream-selector":
        return parse_downstream_selector(node_name, node_data, eth_map)

    if normalized_role == "wan-peer":
        return parse_wan_peer(node_name, node_data, eth_map)

    return {"node": node_name, "role": normalized_role, "links": {}}


def _default_cm_inputs(
    role: str,
    node_data: Dict[str, Any],
    parsed: Dict[str, Any],
) -> Dict[str, Any]:
    cm_inputs: Dict[str, Any] = {}

    containerlab = node_data.get("containerlab", {})
    if not isinstance(containerlab, dict):
        containerlab = {}

    roles_cfg = containerlab.get("roles", {})
    if not isinstance(roles_cfg, dict):
        roles_cfg = {}

    role_cfg = roles_cfg.get(role, {})
    if not isinstance(role_cfg, dict):
        role_cfg = {}

    # Forwarding defaults are environment/runtime concerns; keep them inventory-driven.
    disable_eth0_default = role not in {"wan-peer", "isp", "core"}
    disable_eth0 = disable_eth0_default
    role_forwarding = role_cfg.get("forwarding", {})
    if isinstance(role_forwarding, dict) and "disable_eth0" in role_forwarding:
        disable_eth0 = bool(role_forwarding.get("disable_eth0"))

    if role in {
        "core",
        "downstream-selector",
        "policy",
        "upstream-selector",
        "wan-peer",
        "isp",
    }:
        cm_inputs["forwarding"] = {
            "enable_ipv4": True,
            "enable_ipv6": True,
            "disable_eth0": disable_eth0,
        }

    cm_inputs["management_egress"] = {"interface": "eth0"}

    if role == "core":
        wan_link = (parsed.get("links") or {}).get("wan") or {}
        wan_eth = wan_link.get("eth")
        wan_if = f"eth{wan_eth}" if isinstance(wan_eth, int) else None

        cm_inputs["wan_firewall"] = {
            "wan_interfaces": [wan_if] if isinstance(wan_if, str) else [],
            "masquerade": _core_egress_masquerade(node_data, role_cfg, wan_if),
        }

    if role == "policy":
        policy_firewall_state = node_data.get("policy_firewall_state", {})
        if isinstance(policy_firewall_state, dict):
            cm_inputs["firewall"] = policy_firewall_state

    if role == "wan-peer":
        fabric_link = (parsed.get("links") or {}).get("fabric") or {}
        fabric_eth = fabric_link.get("eth")
        if isinstance(fabric_eth, int):
            cm_inputs["nat"] = {
                "wan_interface": f"eth{fabric_eth}",
            }

    return cm_inputs


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
    routing_mode: str = "static",
    disable_dynamic: bool = True,
) -> List[str]:
    _ = routing_mode
    _ = disable_dynamic

    parsed = _parse(role, node_name, node_data, eth_map)
    node_data["_s88_links"] = parsed
    node_data["_cm_inputs"] = _default_cm_inputs(role, node_data, parsed)

    return render_default(role, node_name, node_data, eth_map)
