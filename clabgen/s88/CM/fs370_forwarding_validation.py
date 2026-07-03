from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Tuple

from clabgen.s88.CM.linux_route_values import _dst, _normalize_prefix, _route_lists
from clabgen.s88.CM.linux_route_via import _effective_via4, _effective_via6
from clabgen.s88.CM.linux_routes import _main_default_route_allowed


_RULE_PATTERN = (
    r"ip(?P<v6>\s+-6)?\s+rule\s+add\s+to\s+(?P<dst>\S+)\s+"
    r"iif\s+(?P<iif>\S+)\s+priority\s+(?P<priority>\d+)\s+table\s+(?P<table>\d+)"
)


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _commands_text(commands: Iterable[str]) -> str:
    return "\n".join(str(command) for command in commands)


def _runtime_name(value: Any, eth_map: Dict[str, str]) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return eth_map.get(value, value)


def _forward_rules(node: Dict[str, Any]) -> List[Dict[str, Any]]:
    forwarding_intent = _dict(node.get("forwardingIntent"))
    rules = forwarding_intent.get("rules")
    return [rule for rule in rules if isinstance(rule, dict)] if isinstance(rules, list) else []


def _route_command_fragments(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[Tuple[str, str]]:
    if node.get("role") != "access":
        return []
    fragments: List[Tuple[str, str]] = []
    interfaces = _dict(node.get("interfaces"))
    for ifname, iface in interfaces.items():
        if not isinstance(iface, dict):
            continue
        eth = eth_map.get(ifname)
        if eth is None:
            continue
        routes = _route_lists(iface)
        for route in routes["ipv4"]:
            if route.get("policyOnly") is True:
                continue
            dst = _dst(route)
            via = _effective_via4(node, iface, route)
            if not dst or not via:
                continue
            if dst == "0.0.0.0/0" and not _main_default_route_allowed(node, iface, route):
                continue
            rendered_dst = "default" if dst == "0.0.0.0/0" else _normalize_prefix(dst)
            fragments.append((dst, f"ip route replace {rendered_dst} via {via} dev {eth}"))
        for route in routes["ipv6"]:
            if route.get("policyOnly") is True:
                continue
            dst = _dst(route)
            via = _effective_via6(node, iface, route)
            if not dst or not via:
                continue
            if dst == "::/0" and not _main_default_route_allowed(node, iface, route):
                continue
            rendered_dst = "default" if dst == "::/0" else _normalize_prefix(dst)
            fragments.append((dst, f"ip -6 route replace {rendered_dst} via {via} dev {eth}"))
    return fragments


def _validate_no_bad_comments(commands: List[str]) -> None:
    for command in commands:
        if "nft" in command and "no-uplink" in command:
            raise ValueError(
                "wrong-comment diagnostic: FS-370-HDS-010-SDS-010-SMS-110 "
                "renderer emitted no-uplink on an internet-covered fabric path"
            )


def _validate_forward_accepts(node: Dict[str, Any], eth_map: Dict[str, str], text: str) -> None:
    for rule in _forward_rules(node):
        if rule.get("action") != "accept":
            continue
        from_eth = _runtime_name(rule.get("fromInterface"), eth_map)
        to_eth = _runtime_name(rule.get("toInterface"), eth_map)
        if from_eth is None or to_eth is None:
            continue
        if (
            f'iifname "{from_eth}"' in text
            and f'oifname "{to_eth}"' in text
            and "counter accept" in text
        ):
            continue
        raise ValueError(
            "missing-tenant-accept diagnostic: FS-370-HDS-010-SDS-010-SMS-110 "
            f"missing accept rule for {from_eth}->{to_eth}"
        )


def _validate_access_routes(node: Dict[str, Any], eth_map: Dict[str, str], text: str) -> None:
    for dst, fragment in _route_command_fragments(node, eth_map):
        if fragment in text:
            continue
        raise ValueError(
            "missing-selector-route diagnostic: FS-370-HDS-010-SDS-010-SMS-110 "
            f"missing access route for {dst}"
        )


def _validate_policy_rules(commands: List[str]) -> None:
    claimed: Dict[Tuple[str, str, str], Tuple[int, int]] = {}
    for command in commands:
        match = re.search(_RULE_PATTERN, command)
        if match is None:
            continue
        family = "6" if match.group("v6") else "4"
        dst = match.group("dst")
        iif = match.group("iif")
        if dst in {"0.0.0.0/0", "::/0"}:
            raise ValueError(
                "prohibited-default-route diagnostic: FS-370-HDS-010-SDS-010-SMS-110 "
                f"default-route catch-all on shared interface {iif}"
            )
        key = (family, dst, iif)
        value = (int(match.group("priority")), int(match.group("table")))
        previous = claimed.get(key)
        if previous is not None and previous != value:
            raise ValueError(
                "diagnostic.priority-inversion-route-capture: "
                "FS-370-HDS-010-SDS-010-SMS-110 duplicate destination/iif "
                f"policy rule for {dst} on {iif}"
            )
        claimed[key] = value


def validate_fs370_forwarding_commands(
    node: Dict[str, Any], eth_map: Dict[str, str], commands: List[str]
) -> None:
    text = _commands_text(commands)
    _validate_no_bad_comments(commands)
    _validate_forward_accepts(node, eth_map, text)
    _validate_access_routes(node, eth_map, text)
    _validate_policy_rules(commands)


def validate_fs370_counter_snapshot(
    node: Dict[str, Any], eth_map: Dict[str, str], counter_lines: List[str]
) -> None:
    if node.get("role") != "core":
        return
    text = _commands_text(counter_lines)
    for rule in _forward_rules(node):
        if rule.get("action") != "accept":
            continue
        from_eth = _runtime_name(rule.get("fromInterface"), eth_map)
        to_eth = _runtime_name(rule.get("toInterface"), eth_map)
        if from_eth is None or to_eth is None:
            continue
        if (
            f'iifname "{from_eth}"' in text
            and f'oifname "{to_eth}"' in text
            and re.search(r"counter\s+packets\s+0\b", text)
        ):
            raise ValueError(
                "core-forward-counter-zero diagnostic: "
                "FS-370-HDS-010-SDS-010-SMS-110 core forward counter stayed at zero"
            )
