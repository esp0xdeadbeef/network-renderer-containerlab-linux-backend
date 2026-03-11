# ./clabgen/s88/CM/policy_firewall.py
from __future__ import annotations

from typing import Any, Dict, List


def _members(obj: Any) -> List[str]:
    if isinstance(obj, str):
        return [obj]

    if isinstance(obj, list):
        result: List[str] = []
        for item in obj:
            result.extend(_members(item))
        return result

    if not isinstance(obj, dict):
        return []

    kind = obj.get("kind")

    if kind in {"tenant", "tenant-set"}:
        members = obj.get("members")
        if isinstance(members, list):
            return [str(m) for m in members if isinstance(m, str)]
        name = obj.get("name")
        if isinstance(name, str):
            return [name]

    if kind in {"external", "service"}:
        name = obj.get("name")
        if isinstance(name, str):
            return [name]

    return []


def _relation_objects(contract: Dict[str, Any]) -> List[Dict[str, Any]]:
    relations = contract.get("allowedRelations") or contract.get("relations")
    if not isinstance(relations, list):
        raise RuntimeError("communicationContract.allowedRelations must be array")
    return [r for r in relations if isinstance(r, dict)]


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
        return [int(v) for v in value]

    raise RuntimeError("invalid dports")


def _rule_for_match(src_if: str, dst_if: str, match: Dict[str, Any], action: str) -> str:
    proto = _proto(match)
    dports = _dports(match)

    rule = f'nft add rule inet fw forward iifname "{src_if}" oifname "{dst_if}"'

    if proto:
        rule += f" {proto}"

    if dports:
        if len(dports) == 1:
            rule += f" dport {dports[0]}"
        else:
            ports = ", ".join(str(p) for p in dports)
            rule += f" dport {{ {ports} }}"

    rule += f" {action}"
    return rule


def render(node_name: str, node_data: Dict[str, Any]) -> List[str]:
    _ = node_name

    firewall_context = node_data.get("firewall_context", {})
    if not isinstance(firewall_context, dict):
        raise RuntimeError("missing firewall_context")

    policy_context = firewall_context.get("policy")
    if not isinstance(policy_context, dict):
        raise RuntimeError("missing firewall_context.policy")

    zones = policy_context.get("zones")
    if not isinstance(zones, dict):
        raise RuntimeError("missing policy firewall zones")

    enterprise = node_data.get("enterprise")
    if not isinstance(enterprise, dict):
        raise RuntimeError("missing enterprise context")

    site_obj: Dict[str, Any] | None = None
    for enterprise_obj in enterprise.values():
        if not isinstance(enterprise_obj, dict):
            continue
        site_root = enterprise_obj.get("site")
        if not isinstance(site_root, dict):
            continue
        for candidate in site_root.values():
            if isinstance(candidate, dict):
                site_obj = candidate
                break
        if site_obj is not None:
            break

    if site_obj is None:
        raise RuntimeError("missing site context")

    contract = site_obj.get("communicationContract")
    if not isinstance(contract, dict):
        raise RuntimeError("missing communicationContract")

    relations = _relation_objects(contract)

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

    for relation in relations:
        src_members = _members(relation.get("from"))
        dst_obj = relation.get("to")

        if dst_obj == "any":
            dst_members = list(zones.keys())
        else:
            dst_members = _members(dst_obj)

        matches = relation.get("match") or []
        action = "accept" if relation.get("action") == "allow" else "drop"

        for s in src_members:
            for d in dst_members:
                if s == d:
                    continue

                src_if = zones.get(s)
                dst_if = zones.get(d)

                if not src_if or not dst_if:
                    continue

                for m in matches:
                    rule = _rule_for_match(src_if, dst_if, m, action)
                    if rule not in emitted:
                        emitted.add(rule)
                        cmds.append(rule)

    cmds.append("nft list table inet fw")

    return cmds
