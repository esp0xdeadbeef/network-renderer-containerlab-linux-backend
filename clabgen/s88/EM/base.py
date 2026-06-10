from __future__ import annotations

from typing import Any, Dict, List

from .default import render as render_default
from .interface_names import require_runtime_name, translate_names
from ..CM._wan_index import peek_wan_index


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
    # Diagnostic: check if core-uplink-egress is in interfaces
    has_egress = "core-uplink-egress" in interfaces
    if not has_egress:
        for ln, iface in interfaces.items():
            if isinstance(iface, dict) and iface.get("runtimeIfName") == "core-uplink-egress":
                has_egress = True
                break
    if not has_egress:
        import sys
        node_name = node_data.get("name", node_data.get("nodeName", "unknown"))
        all_runtime_names = [
            iface.get("runtimeIfName") if isinstance(iface, dict) else None
            for iface in interfaces.values()
        ]
        print(f"DIAGNOSTIC: node={node_name!r} has core-uplink-egress? {has_egress}", file=sys.stderr)
        print(f"DIAGNOSTIC: node={node_name!r} interface runtimeNames: {[r for r in all_runtime_names if r]}", file=sys.stderr)
    for logical_name, iface in interfaces.items():
        if not isinstance(logical_name, str) or not isinstance(iface, dict):
            continue
        if logical_name not in eth_map:
            # Allow PPPoE session interfaces to map to themselves
            if iface.get("sourceKind") == "pppoe-session":
                result[logical_name] = logical_name
            # Allow synthetic interfaces with explicit runtimeIfName to self-map
            runtime_name = iface.get("runtimeIfName")
            if isinstance(runtime_name, str) and runtime_name:
                result[runtime_name] = runtime_name
            continue
        target_name = eth_map[logical_name]
        result[logical_name] = target_name
        runtime_name = iface.get("runtimeIfName")
        if isinstance(runtime_name, str) and runtime_name:
            result[runtime_name] = target_name
    return result


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
        translated["fromInterface"] = require_runtime_name(
            rule.get("fromInterface"), name_map, "forwardingIntent.rules.fromInterface"
        )
        translated["toInterface"] = require_runtime_name(
            rule.get("toInterface"), name_map, "forwardingIntent.rules.toInterface"
        )
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


def _interface_subnets4(interfaces: Dict[str, Any]) -> List[str]:
    """Derive IPv4 subnets from node interfaces for NAT masquerade augmentation."""
    import ipaddress
    subnets: List[str] = []
    for _ln, iface in interfaces.items():
        if not isinstance(iface, dict):
            continue
        # Skip WAN/overlay interfaces — those are egress surfaces, not internal subnets
        kind = iface.get("kind", "")
        if kind in ("wan", "overlay"):
            continue
        addr4 = iface.get("addr4")
        if isinstance(addr4, str) and addr4:
            try:
                net = ipaddress.IPv4Network(addr4, strict=False)
                subnets.append(str(net))
            except ValueError:
                pass
    return subnets


def _fabric_private_ranges() -> List[str]:
    """Broad private IPv4 ranges that cover all fabric-internal addressing."""
    return ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]


def _masquerade_from_nat_intent(
    nat_intent: Dict[str, Any],
    interfaces: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
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

    source4 = _list_strings(nat_intent.get("masqueradeSourcePrefixes4"))
    # Augment with all fabric-internal private ranges so transit traffic
    # from any node (provider, selector, access) gets NATed through the core.
    fabric_ranges = _fabric_private_ranges()
    seen = set(source4)
    for s in fabric_ranges:
        if s not in seen:
            source4.append(s)
            seen.add(s)
    if source4:
        result["saddr4"] = source4

    return result


def _wan_firewall_cm_input(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    name_map = _interface_name_map(node_data, eth_map)
    forwarding_intent = _dict(node_data.get("forwardingIntent"))
    nat_intent = _dict(node_data.get("natIntent"))

    wan_interfaces = translate_names(
        _list_strings(nat_intent.get("wanInterfaces")),
        name_map,
        "natIntent.wanInterfaces",
    )
    if not wan_interfaces:
        wan_interfaces = translate_names(
            _list_strings(forwarding_intent.get("uplinkInterfaces")),
            name_map,
            "forwardingIntent.uplinkInterfaces",
        )

    masquerade = _masquerade_from_nat_intent(nat_intent, node_data.get("interfaces"))
    if masquerade:
        masquerade["oifnames"] = translate_names(
            _list_strings(masquerade.get("oifnames")),
            name_map,
            "natIntent.masqueradeInterfaces",
        )
        # Compute dedicated SNAT IP matching the /32 IP assigned by
        # linux_wan_dynamic.py. Uses the shared _wan_index counter so
        # both modules produce the same IP per container.
        if masquerade.get("ipv4") and masquerade.get("oifnames"):
            snat_idx = peek_wan_index()
            masquerade["snat_ip"] = f"10.11.0.{200 + snat_idx}"
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
    # Self-map any forwarding-rule interface references not in the per-node name_map.
    # Synthetic interfaces (e.g. core-uplink-egress) live on a different node
    # but forwarding rules on peer nodes reference them by runtime name.
    def _add_missing_key(value: Any) -> None:
        if isinstance(value, str) and value and value not in name_map:
            # Allow any string that looks like a valid interface name to self-map.
            # PPPoE session names are already handled in require_runtime_name.
            if not value.startswith("ppp"):
                name_map[value] = value
    rules_list = forwarding_intent.get("rules")
    if isinstance(rules_list, list):
        for rule in rules_list:
            if isinstance(rule, dict):
                _add_missing_key(rule.get("fromInterface"))
                _add_missing_key(rule.get("toInterface"))
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
