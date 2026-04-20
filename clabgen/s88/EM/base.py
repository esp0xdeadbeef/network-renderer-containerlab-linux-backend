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


def _parse(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> Dict[str, Any]:
    r = str(role or "").strip()

    if r == "access":
        return parse_access(node_name, node_data, eth_map)

    if r == "core":
        return parse_core(node_name, node_data, eth_map)

    if r == "policy":
        return parse_policy(node_name, node_data, eth_map)

    if r == "upstream-selector":
        return parse_upstream_selector(node_name, node_data, eth_map)

    if r == "downstream-selector":
        return parse_downstream_selector(node_name, node_data, eth_map)

    if r == "wan-peer":
        return parse_wan_peer(node_name, node_data, eth_map)

    return {"node": node_name, "role": r, "links": {}}


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

    if role in {"core", "downstream-selector", "policy", "upstream-selector", "wan-peer", "isp"}:
        cm_inputs["forwarding"] = {
            "enable_ipv4": True,
            "enable_ipv6": True,
            "disable_eth0": disable_eth0,
        }

    if role == "core":
        wan_link = ((parsed.get("links") or {}).get("wan") or {})
        wan_eth = wan_link.get("eth")
        wan_firewall_cfg = role_cfg.get("wan_firewall", {})
        if not isinstance(wan_firewall_cfg, dict):
            wan_firewall_cfg = {}

        cm_inputs["wan_firewall"] = {
            "wan_interfaces": [f"eth{wan_eth}"] if isinstance(wan_eth, int) else [],
            "masquerade": wan_firewall_cfg.get("masquerade", {}),
        }

    if role == "policy":
        policy_firewall_state = node_data.get("policy_firewall_state", {})
        if isinstance(policy_firewall_state, dict):
            cm_inputs["firewall"] = policy_firewall_state

    if role == "wan-peer":
        fabric_link = ((parsed.get("links") or {}).get("fabric") or {})
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
