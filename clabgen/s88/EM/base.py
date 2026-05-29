from __future__ import annotations

from typing import Any, Dict, List

from .default import render as render_default


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list_strings(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    strings: List[str] = []
    for item in value:
        if isinstance(item, str) and item:
            strings.append(item)
    return strings


def _interface_name_map(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, str]:
    result: Dict[str, str] = {}
    interfaces = _dict(node_data.get("interfaces"))
    for logical_name, iface in interfaces.items():
        if not isinstance(logical_name, str) or not isinstance(iface, dict):
            continue
        if logical_name not in eth_map:
            continue
        target_name = eth_map[logical_name]
        result[logical_name] = target_name
        runtime_name = iface.get("runtimeIfName")
        if isinstance(runtime_name, str) and runtime_name:
            result[runtime_name] = target_name
    return result


def _translate_name(value: Any, name_map: Dict[str, str]) -> Any:
    if isinstance(value, str) and value:
        return name_map.get(value, value)
    return value


def _translate_names(values: List[str], name_map: Dict[str, str]) -> List[str]:
    translated_names: List[str] = []
    for value in values:
        translated = _translate_name(value, name_map)
        if isinstance(translated, str) and translated:
            translated_names.append(translated)
    return translated_names


def _translated_forwarding_rules(
    forwarding_intent: Dict[str, Any],
    name_map: Dict[str, str],
) -> List[Dict[str, Any]]:
    rules = forwarding_intent.get("rules")
    if not isinstance(rules, list):
        return []

    translated_rules: List[Dict[str, Any]] = []
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        translated = dict(rule)
        translated["fromInterface"] = _translate_name(
            rule.get("fromInterface"), name_map
        )
        translated["toInterface"] = _translate_name(rule.get("toInterface"), name_map)
        translated_rules.append(translated)

    return translated_rules


def _forwarding_cm_input(node_data: Dict[str, Any]) -> Dict[str, Any]:
    forwarding_intent = _dict(node_data.get("forwardingIntent"))
    nat_intent = _dict(node_data.get("natIntent"))
    if not forwarding_intent and not nat_intent:
        return {}

    return {
        "enable_ipv4": True,
        "enable_ipv6": True,
        "disable_eth0": True,
    }


def _masquerade_from_nat_intent(nat_intent: Dict[str, Any]) -> Dict[str, Any]:
    if nat_intent.get("enabled") is not True:
        return {}

    families = _dict(nat_intent.get("families"))
    result: Dict[str, Any] = {
        "ipv4": bool(families.get("ipv4", False)),
        "ipv6": bool(families.get("ipv6", False)),
        "oifnames": _list_strings(nat_intent.get("masqueradeInterfaces")),
    }

    source6 = _list_strings(nat_intent.get("masqueradeSourcePrefixes6"))
    if source6:
        result["saddr6"] = source6

    return result


def _wan_firewall_cm_input(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    name_map = _interface_name_map(node_data, eth_map)
    forwarding_intent = _dict(node_data.get("forwardingIntent"))
    nat_intent = _dict(node_data.get("natIntent"))

    wan_interfaces = _translate_names(
        _list_strings(nat_intent.get("wanInterfaces")), name_map
    )
    if not wan_interfaces:
        wan_interfaces = _translate_names(
            _list_strings(forwarding_intent.get("uplinkInterfaces")),
            name_map,
        )

    masquerade = _masquerade_from_nat_intent(nat_intent)
    if masquerade:
        masquerade["oifnames"] = _translate_names(
            _list_strings(masquerade.get("oifnames")),
            name_map,
        )
    if not wan_interfaces and not masquerade:
        return {}

    return {
        "wan_interfaces": wan_interfaces,
        "masquerade": masquerade,
    }


def _firewall_cm_input(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    name_map = _interface_name_map(node_data, eth_map)
    forwarding_intent = _dict(node_data.get("forwardingIntent"))
    rules = _translated_forwarding_rules(forwarding_intent, name_map)
    if not rules:
        return {}

    return {
        "rules": rules,
        "interface_tags": {},
    }


def _cm_inputs_from_contracts(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    cm_inputs: Dict[str, Any] = {}

    forwarding = _forwarding_cm_input(node_data)
    if forwarding:
        cm_inputs["forwarding"] = forwarding

    wan_firewall = _wan_firewall_cm_input(node_data, eth_map)
    if wan_firewall:
        cm_inputs["wan_firewall"] = wan_firewall

    firewall = _firewall_cm_input(node_data, eth_map)
    if firewall:
        cm_inputs["firewall"] = firewall

    cm_inputs["management_egress"] = {"interface": "eth0"}

    return cm_inputs


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
    routing_mode: str = "static",
    disable_dynamic: bool = True,
) -> List[str]:
    _ = routing_mode
    _ = disable_dynamic

    node_data["_cm_inputs"] = _cm_inputs_from_contracts(node_data, eth_map)

    return render_default(role, node_name, node_data, eth_map)
