from __future__ import annotations

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
            f"{prefix_part}"
        )

        if traffic_type == "dns":
            rules.append(f"{base} udp dport 53 counter {action}")
            rules.append(f"{base} tcp dport 53 counter {action}")
        else:
            rules.append(f"{base} counter {action}")

    return rules
