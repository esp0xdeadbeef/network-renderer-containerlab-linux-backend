from __future__ import annotations

from typing import Any, Dict, List
import json

from clabgen.s88.site.policy_contract import endpoint_members, relation_objects


def build_policy_rules(
    contract: Dict[str, Any],
    known_tags: set[str],
    service_tenants: Dict[str, List[str]],
):
    rules = []
    traffic_types_raw = contract.get("trafficTypes") or []
    traffic_type_matches: Dict[str, List[Dict[str, Any]]] = {}
    if isinstance(traffic_types_raw, list):
        for obj in traffic_types_raw:
            if not isinstance(obj, dict):
                continue
            name = obj.get("name")
            matches = obj.get("match")
            if isinstance(name, str) and name and isinstance(matches, list):
                valid_matches: List[Dict[str, Any]] = []
                for match in matches:
                    if isinstance(match, dict):
                        valid_matches.append(match)
                traffic_type_matches[name] = valid_matches

    for relation in relation_objects(contract):
        src_members = endpoint_members(relation.get("from"), service_tenants)
        dst = relation.get("to")
        if dst == "any":
            dst_members = sorted(known_tags)
        else:
            dst_members = endpoint_members(dst, service_tenants)

        action = "drop"
        if relation.get("action") == "allow":
            action = "accept"
        matches = relation.get("match") or relation.get("matches") or []

        if matches == []:
            traffic_type = relation.get("trafficType")
            if isinstance(traffic_type, str) and traffic_type:
                if traffic_type == "any":
                    matches = [{"family": "any", "proto": "any", "dports": []}]
                elif traffic_type in traffic_type_matches:
                    matches = traffic_type_matches[traffic_type]
                else:
                    raise RuntimeError(
                        "communicationContract.allowedRelations references unknown trafficType\n"
                        + json.dumps(
                            {
                                "trafficType": traffic_type,
                                "knownTrafficTypes": sorted(
                                    traffic_type_matches.keys()
                                ),
                                "relation": relation,
                            },
                            indent=2,
                            default=str,
                        )
                    )

        if not isinstance(matches, list):
            raise RuntimeError(
                "communicationContract.allowedRelations match must be an array\n"
                + json.dumps({"relation": relation}, indent=2, default=str)
            )

        for src_tenant in src_members:
            for dst_tenant in dst_members:
                if src_tenant == dst_tenant:
                    continue
                if src_tenant not in known_tags or dst_tenant not in known_tags:
                    continue
                rules.append(
                    {
                        "src_tenant": src_tenant,
                        "dst_tenant": dst_tenant,
                        "action": action,
                        "matches": matches,
                    }
                )
    return rules
