from __future__ import annotations

from typing import Any, Dict, List

from .cpm_firewall_rules import rules_for_cpm_rule


def _proto(match: Dict[str, Any]) -> str | None:
    proto = match.get("proto")
    if proto is None:
        return None
    proto = str(proto).lower()
    if proto == "any":
        return None
    return proto


def _dports(match: Dict[str, Any]) -> List[int]:
    value = match.get("dports")
    if value is None:
        return []

    if isinstance(value, int):
        return [value]

    if isinstance(value, list):
        ports: List[int] = []
        for raw_port in value:
            ports.append(int(raw_port))
        return ports

    raise RuntimeError("invalid dports")


def _tenant_interfaces(interface_tags: Dict[str, Any], tenant: str) -> List[str]:
    matches: List[str] = []

    for ifname, tagged_tenant in interface_tags.items():
        if tagged_tenant == tenant:
            matches.append(ifname)
            continue

        if isinstance(tagged_tenant, list) and tenant in tagged_tenant:
            matches.append(ifname)

    return sorted(matches)


def _set_expr(values: List[str]) -> str:
    if len(values) == 1:
        return f'"{values[0]}"'
    quoted_values: List[str] = []
    for value in values:
        quoted_values.append(f'"{value}"')
    return "{ " + ", ".join(quoted_values) + " }"


def _rule_for_match(
    src_ifaces: List[str],
    dst_ifaces: List[str],
    match: Dict[str, Any],
    action: str,
) -> str:
    proto = _proto(match)
    dports = _dports(match)

    rule = (
        "nft add rule inet fw forward "
        f"iifname {_set_expr(src_ifaces)} "
        f"oifname {_set_expr(dst_ifaces)}"
    )

    if proto == "icmp":
        rule += " meta l4proto icmp"
    elif proto:
        rule += f" {proto}"

    if dports:
        if len(dports) == 1:
            rule += f" dport {dports[0]}"
        else:
            port_values: List[str] = []
            for destination_port in dports:
                port_values.append(str(destination_port))
            ports = ", ".join(port_values)
            rule += f" dport {{ {ports} }}"

    rule += f" counter {action}"
    return rule


def render(input_data: Dict[str, Any]) -> List[str]:
    interface_tags = input_data.get("interface_tags", {})
    if not isinstance(interface_tags, dict):
        raise RuntimeError("missing firewall interface_tags")

    rules = input_data.get("rules", [])
    if not isinstance(rules, list):
        raise RuntimeError("missing firewall rules")

    cmds: List[str] = [
        "echo '[FW] policy firewall starting'",
        "nft add table inet fw",
        "nft 'add chain inet fw forward { type filter hook forward priority 0 ; policy drop ; }'",
        "nft add rule inet fw forward ct state established,related accept",
        "nft add rule inet fw forward ct state invalid drop",
        'nft add rule inet fw forward iifname "eth0" drop',
        'nft add rule inet fw forward oifname "eth0" drop',
    ]

    emitted: set[str] = set()

    for rule_obj in rules:
        if not isinstance(rule_obj, dict):
            continue

        cpm_rules = rules_for_cpm_rule(rule_obj)
        if cpm_rules:
            for rule in cpm_rules:
                if rule not in emitted:
                    emitted.add(rule)
                    cmds.append(rule)
            continue

        src_tenant = rule_obj.get("src_tenant")
        dst_tenant = rule_obj.get("dst_tenant")
        action = "accept" if rule_obj.get("action") == "accept" else "drop"
        matches = rule_obj.get("matches", [])

        if not isinstance(src_tenant, str) or not src_tenant:
            continue
        if not isinstance(dst_tenant, str) or not dst_tenant:
            continue
        if not isinstance(matches, list):
            continue

        src_ifaces = _tenant_interfaces(interface_tags, src_tenant)
        dst_ifaces = _tenant_interfaces(interface_tags, dst_tenant)

        if not src_ifaces or not dst_ifaces:
            continue

        for match in matches:
            if not isinstance(match, dict):
                continue
            rule = _rule_for_match(
                src_ifaces,
                dst_ifaces,
                match,
                action,
            )
            if rule not in emitted:
                emitted.add(rule)
                cmds.append(rule)

    cmds.append("nft list table inet fw")

    return cmds
