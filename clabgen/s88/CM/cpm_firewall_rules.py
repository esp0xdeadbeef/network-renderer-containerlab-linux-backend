from __future__ import annotations

import shlex
from typing import Any, Dict, List


def _family_prefixes(rule_obj: Dict[str, Any], family: int) -> List[str]:
    values = rule_obj.get("sourcePrefixes")
    if not isinstance(values, list):
        return []

    prefixes: List[str] = []
    for value in values:
        prefix = None
        prefix_family = family
        if isinstance(value, str):
            prefix = value
            prefix_family = 6 if ":" in value else 4
        elif isinstance(value, dict):
            raw_prefix = value.get("prefix")
            raw_family = value.get("family")
            if isinstance(raw_prefix, str) and raw_prefix:
                prefix = raw_prefix
            if raw_family in (4, 6):
                prefix_family = raw_family

        if prefix is not None and prefix_family == family:
            prefixes.append(prefix)

    return prefixes


def _prefix_expr(prefixes: List[str]) -> str:
    if len(prefixes) == 1:
        return prefixes[0]
    return "{ " + ", ".join(prefixes) + " }"


def _match_family_applies(match: Dict[str, Any], family: int) -> bool:
    match_family = match.get("family", "any")
    if match_family == "any":
        return True
    if match_family in (family, str(family)):
        return True
    if family == 4 and match_family in ("ipv4", "ip"):
        return True
    if family == 6 and match_family in ("ipv6", "ip6"):
        return True
    return False


def _dports_expr(match: Dict[str, Any]) -> str:
    raw_dports = match.get("dports")
    if raw_dports is None:
        return ""
    if isinstance(raw_dports, int):
        return f" dport {raw_dports}"
    if not isinstance(raw_dports, list):
        return ""

    ports: List[str] = []
    for raw_port in raw_dports:
        if isinstance(raw_port, int):
            ports.append(str(raw_port))
    if not ports:
        return ""
    if len(ports) == 1:
        return f" dport {ports[0]}"
    return " dport { " + ", ".join(ports) + " }"


def _match_suffix(match: Dict[str, Any], family: int) -> str | None:
    if not _match_family_applies(match, family):
        return None

    proto = match.get("proto")
    proto_text = "" if proto in (None, "any") else str(proto).lower()
    dports = _dports_expr(match)

    if proto_text == "icmp":
        return " meta l4proto icmp"
    if proto_text:
        return f" {proto_text}{dports}"
    return dports


def _explicit_match_suffixes(rule_obj: Dict[str, Any], family: int) -> List[str]:
    matches = rule_obj.get("matches")
    if not isinstance(matches, list):
        return []

    suffixes: List[str] = []
    for match in matches:
        if not isinstance(match, dict):
            continue
        suffix = _match_suffix(match, family)
        if suffix is not None:
            suffixes.append(suffix)
    return suffixes


def _identity_comment(rule_obj: Dict[str, Any]) -> str:
    for field in ("relationId", "policyId", "sourceRelationId", "comment"):
        value = rule_obj.get(field)
        if isinstance(value, str) and value:
            return f" comment {shlex.quote(value)}"
    return ""


def _connection_state_expr(rule_obj: Dict[str, Any]) -> str:
    state = rule_obj.get("connectionState")
    is_return_rule = rule_obj.get("returnRule") is True

    if state in (None, ""):
        if is_return_rule:
            relation_id = rule_obj.get("relationId") or "<unknown>"
            raise ValueError(
                "FS-230-HDS-010-SDS-010-SMS-030: reverse return rule "
                f"{relation_id!r} carries no connection-state restriction "
                "(reverse-new-flow authority invention)"
            )
        return ""

    if state != "established,related":
        relation_id = rule_obj.get("relationId") or "<unknown>"
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-030: forwarding rule "
            f"{relation_id!r} carries unsupported connectionState {state!r}"
        )

    return " ct state established,related"


def rules_for_cpm_rule(rule_obj: Dict[str, Any]) -> List[str]:
    from_interface = rule_obj.get("fromInterface")
    to_interface = rule_obj.get("toInterface")
    if not isinstance(from_interface, str) or not from_interface:
        return []
    if not isinstance(to_interface, str) or not to_interface:
        return []

    action = "accept" if rule_obj.get("action") == "accept" else "drop"
    traffic_type = rule_obj.get("trafficType")
    family = rule_obj.get("family")
    families = [family] if family in (4, 6) else [4, 6]
    comment = _identity_comment(rule_obj)
    connection_state = _connection_state_expr(rule_obj)

    rules: List[str] = []
    for rule_family in families:
        prefix_part = ""
        prefixes = _family_prefixes(rule_obj, rule_family)
        if prefixes:
            prefix_part = (
                f" ip{'6' if rule_family == 6 else ''} saddr {_prefix_expr(prefixes)}"
            )

        base = (
            "nft add rule inet fw forward "
            f'iifname "{from_interface}" '
            f'oifname "{to_interface}"'
            f"{connection_state}"
            f"{prefix_part}"
        )

        match_suffixes = _explicit_match_suffixes(rule_obj, rule_family)
        if match_suffixes:
            for suffix in match_suffixes:
                rules.append(f"{base}{suffix} counter {action}{comment}")
        elif traffic_type == "dns":
            rules.append(f"{base} udp dport 53 counter {action}{comment}")
            rules.append(f"{base} tcp dport 53 counter {action}{comment}")
        else:
            rules.append(f"{base} counter {action}{comment}")

    return rules
