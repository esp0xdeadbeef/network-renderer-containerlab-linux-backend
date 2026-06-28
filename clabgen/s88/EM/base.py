from __future__ import annotations

from typing import Any, Dict, List

from .default import render as render_default
from .interface_names import require_runtime_name, translate_names


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
    # Diagnostic: check if any WAN-kind egress interfaces are present.
    # CPM emits kind="wan" for uplink/egress interfaces; the name
    # "core-uplink-egress" is a specific synthetic instance, not the kind.
    has_egress = any(
        isinstance(iface, dict) and iface.get("kind") == "wan"
        for iface in interfaces.values()
    )
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
    if not wan_interfaces and not masquerade:
        return {}

    return {
        "wan_interfaces": wan_interfaces,
        "masquerade": masquerade,
    }


def _pppoe_session_interface_names(
    node_data: Dict[str, Any],
    name_map: Dict[str, str],
) -> List[str]:
    """Derive PPPoE session interface names from CPM services.pppoe data
    and the node's interface records.  Returns runtime interface names
    (e.g. "ppp0") that appear in the CPM-provided forwarding surface."""
    services = _dict(node_data.get("services"))
    pppoe = _dict(services.get("pppoe"))
    if not pppoe:
        return []

    ppp_ifaces: List[str] = []

    # Client: the client's runtimeInterface names the PPP session.
    client = _dict(pppoe.get("client"))
    client_rt = client.get("runtimeInterface")
    if isinstance(client_rt, str) and client_rt:
        resolved = require_runtime_name(
            client_rt, name_map, "services.pppoe.client.runtimeInterface"
        )
        if resolved and resolved not in ppp_ifaces:
            ppp_ifaces.append(resolved)

    # Server: the server itself does not carry runtimeInterface, but the CPM
    # may attach a synthetic PPPoE-session interface record to the node's
    # effectiveRuntimeRealization.interfaces with sourceKind="pppoe-session".
    interfaces = _dict(node_data.get("interfaces"))
    for ifname, iface in interfaces.items():
        if not isinstance(iface, dict):
            continue
        kind_candidate = iface.get("kind") or iface.get("sourceKind")
        # KNOWN_GAP: CPM may attach PPPoE-session interfaces with either
        # field name.  When both are absent we skip rather than falling
        # through to an empty-string default that would hide the gap.
        if not isinstance(kind_candidate, str) or not kind_candidate:
            continue
        if kind_candidate != "pppoe-session":
            continue
        # Resolve through name_map (which self-maps ppp names)
        resolved = require_runtime_name(
            ifname, name_map, f"interfaces.{ifname}.pppoe-session"
        )
        if resolved and resolved not in ppp_ifaces:
            ppp_ifaces.append(resolved)

    return ppp_ifaces


def _augment_pppoe_forwarding_rules(
    node_data: Dict[str, Any],
    forwarding_intent: Dict[str, Any],
    name_map: Dict[str, str],
) -> List[Dict[str, Any]]:
    """Derive additional forwarding rules for PPPoE session interfaces.

    When a node carries PPPoE services and CPM has already supplied
    forwardingIntent.rules for other interface pairs, the PPP session
    interface (e.g. ppp0) needs explicit accept rules in the inet fw
    forward chain to avoid being dropped by the chain's policy-drop
    default.

    Returns only rules whose fromInterface/toInterface are already
    resolvable through name_map, so every rule stays data-driven from
    CPM-provided interface records and services.pppoe fields."""
    ppp_ifaces = _pppoe_session_interface_names(node_data, name_map)
    if not ppp_ifaces:
        return []

    # Collect the set of forwarding-eligible peer interfaces from the
    # existing CPM forwardingIntent rules.  These are the interfaces
    # that CPM already considers part of the forwarding surface for
    # this node.
    existing_rules = forwarding_intent.get("rules")
    peer_runtime_names: List[str] = []
    seen: set[str] = set()
    if isinstance(existing_rules, list):
        for rule in existing_rules:
            if not isinstance(rule, dict):
                continue
            for side in ("fromInterface", "toInterface"):
                raw = rule.get(side)
                if not isinstance(raw, str) or not raw:
                    continue
                try:
                    resolved = require_runtime_name(raw, name_map, side)
                except ValueError:
                    continue
                if resolved and resolved not in seen:
                    seen.add(resolved)
                    peer_runtime_names.append(resolved)

    # Remove the PPPoE session interfaces themselves — we want the OTHER
    # interfaces on the node.
    ppp_set = set(ppp_ifaces)
    peers = [n for n in peer_runtime_names if n not in ppp_set]
    if not peers:
        return []

    # Build existing (from, to) pairs so we don't emit duplicates.
    existing_pairs: set[tuple[str, str]] = set()
    if isinstance(existing_rules, list):
        for rule in existing_rules:
            if not isinstance(rule, dict):
                continue
            fi_raw = rule.get("fromInterface")
            ti_raw = rule.get("toInterface")
            if not isinstance(fi_raw, str) or not isinstance(ti_raw, str):
                continue
            try:
                fi = require_runtime_name(fi_raw, name_map, "fromInterface")
                ti = require_runtime_name(ti_raw, name_map, "toInterface")
            except ValueError:
                continue
            existing_pairs.add((fi, ti))

    new_rules: List[Dict[str, Any]] = []
    for ppp_iface in ppp_ifaces:
        for peer_iface in peers:
            # Forward: peer -> ppp
            if (peer_iface, ppp_iface) not in existing_pairs:
                new_rules.append({
                    "action": "accept",
                    "fromInterface": peer_iface,
                    "toInterface": ppp_iface,
                    "relationId": f"pppoe-fabric-{peer_iface}-to-{ppp_iface}",
                    "comment": f"pppoe-fabric:{peer_iface}->{ppp_iface}",
                })
            # Reverse: ppp -> peer
            if (ppp_iface, peer_iface) not in existing_pairs:
                new_rules.append({
                    "action": "accept",
                    "fromInterface": ppp_iface,
                    "toInterface": peer_iface,
                    "relationId": f"pppoe-fabric-{ppp_iface}-to-{peer_iface}",
                    "comment": f"pppoe-fabric:{ppp_iface}->{peer_iface}",
                })

    return new_rules


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

    # Augment with PPPoE-derived forwarding rules from CPM services.pppoe data.
    # FS-800 fabric egress: provider-handoff containers with PPPoE sessions need
    # explicit forward accept rules between the PPP interface and the fabric/ISP
    # interfaces, otherwise the inet fw forward policy-drop blocks the paths.
    pppoe_rules = _augment_pppoe_forwarding_rules(node_data, forwarding_intent, name_map)
    if pppoe_rules:
        augmented_intent = dict(forwarding_intent)
        augmented_rules = list(rules_list if isinstance(rules_list, list) else [])
        augmented_rules.extend(pppoe_rules)
        augmented_intent["rules"] = augmented_rules
        rules = _translated_forwarding_rules(augmented_intent, name_map)
    else:
        rules = _translated_forwarding_rules(forwarding_intent, name_map)

    if not rules:
        return {}

    return {
        "rules": rules,
        "interface_tags": {},
    }


# FS-320-HDS-010-SDS-010-SMS-030: management eth0 below is the platform
# primary interface passed into CM input after runtime interface mapping.
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

    nat = _nat_cm_input(node_data, eth_map)
    if nat:
        cm_inputs["nat"] = nat

    return cm_inputs


def _nat_cm_input(
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    nat_intent = _dict(node_data.get("natIntent"))
    if nat_intent.get("enabled") is not True:
        return {}

    name_map = _interface_name_map(node_data, eth_map)
    families = _dict(nat_intent.get("families"))
    ipv4 = bool(families.get("ipv4", False))
    ipv6 = bool(families.get("ipv6", False))

    masquerade_ifaces = translate_names(
        _list_strings(nat_intent.get("masqueradeInterfaces")),
        name_map,
        "natIntent.masqueradeInterfaces",
    )

    translation_records = nat_intent.get("translationRecords")
    if isinstance(translation_records, list):
        for record in translation_records:
            if not isinstance(record, dict):
                continue
            egress = _dict(record.get("egressSurface"))
            selected = _list_strings(egress.get("selectedUplinkInterfaces"))
            translated = translate_names(
                selected,
                name_map,
                "translationRecords.egressSurface.selectedUplinkInterfaces",
            )
            for iface in translated:
                if iface not in masquerade_ifaces:
                    masquerade_ifaces.append(iface)

    source4 = _list_strings(nat_intent.get("masqueradeSourcePrefixes4"))
    source6 = _list_strings(nat_intent.get("masqueradeSourcePrefixes6"))

    result: Dict[str, Any] = {
        "ipv4": ipv4,
        "ipv6": ipv6,
        "masqueradeInterfaces": masquerade_ifaces,
    }
    if source4:
        result["saddr4"] = source4
    if source6:
        result["saddr6"] = source6
    return result


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
