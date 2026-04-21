from __future__ import annotations

from typing import Any, Dict, List, Set, Tuple
import json
import re
from collections import deque

from clabgen.models import SiteModel, NodeModel


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
        raise RuntimeError(
            "communicationContract.allowedRelations must be array\n"
            + json.dumps(contract, indent=2, default=str)
        )
    return [r for r in relations if isinstance(r, dict)]


def _contract_tenant_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()

    for relation in _relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if isinstance(endpoint, dict) and endpoint.get("kind") in {"tenant", "tenant-set"}:
                result.update(_members(endpoint))

    return sorted(result)


def _contract_external_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()

    for relation in _relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if isinstance(endpoint, dict) and endpoint.get("kind") == "external":
                result.update(_members(endpoint))

    return sorted(result)


def _policy_peer_map(site: SiteModel, policy_node_name: str, eth_map: Dict[str, int]):
    results = []

    for _, link in sorted(site.links.items(), key=lambda x: x[0]):
        endpoints = link.endpoints
        local = endpoints.get(policy_node_name)

        if not isinstance(local, dict):
            continue

        iface = local.get("interface")
        if iface not in eth_map:
            raise RuntimeError(
                f"missing eth mapping for interface {iface}\n"
                + json.dumps(local, indent=2, default=str)
            )

        peers = [n for n in endpoints if n != policy_node_name]
        if len(peers) != 1:
            raise RuntimeError(
                "policy link must have exactly one peer\n"
                + json.dumps(link.__dict__, indent=2, default=str)
            )

        results.append(
            {
                "eth": eth_map[iface],
                "peer_name": peers[0],
                "link": link.name,
                "policy_iface": iface,
            }
        )

    return results


def _is_loopback_tenant_iface(iface: Any) -> bool:
    tenant = getattr(iface, "tenant", None)
    upstream = getattr(iface, "upstream", None)
    name = getattr(iface, "name", None)

    if tenant == "loopback":
        return True
    if isinstance(name, str) and name == "tenant-loopback":
        return True
    if isinstance(upstream, str) and upstream == "tenant-loopback":
        return True

    return False


def _ownership_tenant_names(site: SiteModel) -> List[str]:
    result: set[str] = set()

    prefixes = (site.raw_ownership or {}).get("prefixes", [])
    if not isinstance(prefixes, list):
        return []

    for prefix in prefixes:
        if not isinstance(prefix, dict):
            continue
        if prefix.get("kind") != "tenant":
            continue

        name = prefix.get("name")
        if isinstance(name, str) and name:
            result.add(name)

    return sorted(result)


def _node_name_candidate_tenants(node_name: str, candidates: List[str]) -> List[str]:
    tokens = [t for t in re.split(r"[^a-zA-Z0-9]+", node_name) if t]
    token_set = {t.lower() for t in tokens}

    matches: List[str] = []
    for candidate in candidates:
        if candidate.lower() in token_set:
            matches.append(candidate)

    return sorted(set(matches))


def _access_node_tenants(site: SiteModel, node: NodeModel) -> List[str]:
    tenants: set[str] = set()

    for iface in node.interfaces.values():
        if getattr(iface, "kind", None) != "tenant":
            continue
        if _is_loopback_tenant_iface(iface):
            continue

        tenant = getattr(iface, "tenant", None)
        if isinstance(tenant, str) and tenant:
            tenants.add(tenant)

    if tenants:
        return sorted(tenants)

    candidate_tenants = sorted(
        set(_contract_tenant_names(dict(site.raw_policy or {})))
        | set(_ownership_tenant_names(site))
    )

    name_matches = _node_name_candidate_tenants(node.name, candidate_tenants)
    if len(name_matches) == 1:
        return name_matches

    if len(candidate_tenants) == 1:
        return candidate_tenants

    debug = {
        "node": node.name,
        "role": node.role,
        "candidate_tenants": candidate_tenants,
        "interfaces": {
            name: getattr(iface, "__dict__", str(iface))
            for name, iface in node.interfaces.items()
        },
    }

    raise RuntimeError(
        "tenant cannot be resolved for access node\n"
        + json.dumps(debug, indent=2, default=str)
    )


def _domains_external_names(site: SiteModel) -> Set[str]:
    domains = dict(site.raw_domains or site.domains or {})
    externals = domains.get("externals", [])

    if isinstance(externals, dict):
        result = {
            name for name, value in externals.items()
            if isinstance(name, str) and name and value is not None
        }
        return result

    if not isinstance(externals, list):
        return set()

    result: Set[str] = set()
    for item in externals:
        if isinstance(item, str) and item:
            result.add(item)
            continue
        if isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str) and name:
                result.add(name)

    return result


def _transport_overlay_specs(site: SiteModel) -> Dict[str, Dict[str, Any]]:
    transport = dict(site.raw_transport or {})
    overlays = transport.get("overlays", [])

    if isinstance(overlays, dict):
        result: Dict[str, Dict[str, Any]] = {}
        for overlay_name, overlay_obj in overlays.items():
            if not isinstance(overlay_name, str) or not overlay_name:
                continue
            if not isinstance(overlay_obj, dict):
                continue
            normalized = dict(overlay_obj)
            normalized.setdefault("name", overlay_name)
            result[overlay_name] = normalized
        return result

    if not isinstance(overlays, list):
        return {}

    result: Dict[str, Dict[str, Any]] = {}
    for overlay in overlays:
        if not isinstance(overlay, dict):
            continue
        name = overlay.get("name")
        if not isinstance(name, str) or not name:
            continue
        result[name] = dict(overlay)

    return result


def _string_list(value: Any) -> List[str]:
    if isinstance(value, str) and value:
        return [value]
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item]


def _single_string_or_only_item(value: Any) -> str | None:
    if isinstance(value, str) and value:
        return value
    values = _string_list(value)
    if len(values) == 1:
        return values[0]
    return None


def _overlay_terminates_on_required_interface(
    site: SiteModel,
    *,
    overlay_name: str,
    terminate_on: str,
) -> bool:
    node = site.nodes.get(terminate_on)
    if node is None:
        raise RuntimeError(
            f"overlay {overlay_name!r} terminateOn node {terminate_on!r} not found"
        )

    for iface in node.interfaces.values():
        if getattr(iface, "kind", None) != "overlay":
            continue
        if getattr(iface, "overlay", None) == overlay_name:
            return True

    return False


def _adjacency(site: SiteModel) -> Dict[str, Set[str]]:
    graph: Dict[str, Set[str]] = {name: set() for name in site.nodes.keys()}

    for link in site.links.values():
        names = [name for name in link.endpoints.keys() if name in site.nodes]
        for src in names:
            graph.setdefault(src, set())
            for dst in names:
                if dst != src:
                    graph[src].add(dst)

    return graph


def _first_hop_from_policy(
    site: SiteModel,
    *,
    policy_node_name: str,
    target_node_name: str,
) -> str | None:
    if policy_node_name == target_node_name:
        return None

    graph = _adjacency(site)
    if policy_node_name not in graph or target_node_name not in graph:
        return None

    queue: deque[str] = deque([policy_node_name])
    parents: Dict[str, str | None] = {policy_node_name: None}

    while queue:
        current = queue.popleft()
        if current == target_node_name:
            break

        for neighbor in sorted(graph.get(current, set())):
            if neighbor in parents:
                continue
            parents[neighbor] = current
            queue.append(neighbor)

    if target_node_name not in parents:
        return None

    current = target_node_name
    prev = parents[current]

    while prev is not None and prev != policy_node_name:
        current = prev
        prev = parents[current]

    if prev != policy_node_name:
        return None

    return current


def _policy_iface_for_peer(
    peer_map: List[Dict[str, Any]],
    peer_name: str,
) -> Tuple[str, str] | None:
    for peer in peer_map:
        if peer.get("peer_name") != peer_name:
            continue
        eth = peer.get("eth")
        if not isinstance(eth, int):
            continue
        return (f"eth{eth}", str(peer.get("policy_iface") or ""))
    return None


def _resolve_external_via_overlay(
    site: SiteModel,
    *,
    policy_node_name: str,
    peer_map: List[Dict[str, Any]],
    external: str,
) -> str | None:
    overlay_specs = _transport_overlay_specs(site)
    overlay = overlay_specs.get(external)
    if overlay is None:
        return None

    terminate_on = _single_string_or_only_item(overlay.get("terminateOn"))
    if not isinstance(terminate_on, str) or not terminate_on:
        raise RuntimeError(
            f"overlay {external!r} missing terminateOn\n"
            + json.dumps(overlay, indent=2, default=str)
        )

    must_traverse = set(_string_list(overlay.get("mustTraverse")))
    if must_traverse and "policy" not in must_traverse:
        raise RuntimeError(
            f"overlay {external!r} does not require policy traversal\n"
            + json.dumps(overlay, indent=2, default=str)
        )

    if not _overlay_terminates_on_required_interface(
        site,
        overlay_name=external,
        terminate_on=terminate_on,
    ):
        raise RuntimeError(
            f"overlay {external!r} has no overlay interface on terminateOn node {terminate_on!r}"
        )

    first_hop = _first_hop_from_policy(
        site,
        policy_node_name=policy_node_name,
        target_node_name=terminate_on,
    )
    if first_hop is None:
        raise RuntimeError(
            f"no topology path from policy node {policy_node_name!r} to overlay terminateOn node {terminate_on!r}"
        )

    resolved = _policy_iface_for_peer(peer_map, first_hop)
    if resolved is None:
        raise RuntimeError(
            f"no policy-facing interface found for first hop {first_hop!r} toward overlay {external!r}"
        )

    eth_ifname, _ = resolved
    return eth_ifname


def _build_policy_interface_tags(
    site: SiteModel,
    policy_node_name: str,
    eth_map: Dict[str, int],
    required_tenants: set[str],
    required_externals: set[str],
) -> Dict[str, str]:
    interface_tags: Dict[str, str] = {}
    peer_map = _policy_peer_map(site, policy_node_name, eth_map)

    def _lane_access_unit(link_name: Any) -> str | None:
        if not isinstance(link_name, str) or "--access-" not in link_name:
            return None
        # Link naming is upstream-owned; for derived lanes we expect:
        #   ...--access-<accessUnit>            (downstream-selector<->policy lanes)
        #   ...--access-<accessUnit>--uplink-*  (policy<->upstream-selector lanes)
        tail = link_name.split("--access-", 1)[1]
        return tail.split("--uplink-", 1)[0]

    for peer in peer_map:
        peer_node = site.nodes.get(peer["peer_name"])

        if peer_node is None:
            raise RuntimeError(
                f"peer node missing: {peer['peer_name']}\n"
                + json.dumps(sorted(site.nodes.keys()), indent=2, default=str)
            )

        iface_name = f"eth{peer['eth']}"

        if peer_node.role == "access":
            tenants = _access_node_tenants(site, peer_node)
            if len(tenants) != 1:
                raise RuntimeError(
                    "policy-facing access node must resolve to exactly one tenant\n"
                    + json.dumps(
                        {
                            "peer_node": peer_node.name,
                            "tenants": tenants,
                        },
                        indent=2,
                        default=str,
                    )
                )
            interface_tags[iface_name] = tenants[0]
            continue

        if peer_node.role == "upstream-selector":
            interface_tags[iface_name] = "wan"
            continue

        if peer_node.role == "downstream-selector":
            # With dedicated lanes enabled upstream, policy<->downstream-selector can be split
            # so each policy-facing interface corresponds to exactly one access unit.
            access_unit = _lane_access_unit(peer.get("link"))
            if access_unit:
                access_node = site.nodes.get(access_unit)
                if access_node is not None and access_node.role == "access":
                    tenants = _access_node_tenants(site, access_node)
                    if len(tenants) == 1:
                        interface_tags[iface_name] = tenants[0]
                        continue
            # If lanes are not enabled, one interface can cover multiple tenants; we can't tag
            # it precisely without inference. Leave it unmapped and let downstream checks warn.
            continue

        if peer_node.role == "core":
            wan_uplinks: List[str] = []
            for core_iface in peer_node.interfaces.values():
                if getattr(core_iface, "kind", None) != "wan":
                    continue
                uplink = getattr(core_iface, "upstream", None)
                if isinstance(uplink, str) and uplink:
                    wan_uplinks.append(uplink)

            wan_uplinks = sorted(set(wan_uplinks))
            interface_tags[iface_name] = wan_uplinks[0] if wan_uplinks else "wan"
            continue

    if not interface_tags:
        raise RuntimeError(
            "policy interface tags cannot be resolved from topology\n"
            + json.dumps(peer_map, indent=2, default=str)
        )

    available_tags = set(interface_tags.values())

    if "wan" not in available_tags and required_externals == {"wan"} and len(available_tags) == 1:
        only_if = next(iter(interface_tags.keys()))
        interface_tags[only_if] = "wan"
        available_tags = {"wan"}

    declared_externals = _domains_external_names(site)

    for external in sorted(required_externals):
        if external in available_tags:
            continue

        if external not in declared_externals:
            raise RuntimeError(
                f"external {external!r} referenced by communicationContract is not declared in site.domains.externals"
            )

        resolved_iface = _resolve_external_via_overlay(
            site,
            policy_node_name=policy_node_name,
            peer_map=peer_map,
            external=external,
        )
        if resolved_iface is None:
            print(
                "WARNING: external has no policy-local tag and no overlay realization:\n"
                + json.dumps(
                    {
                        "external": external,
                        "declared_externals": sorted(declared_externals),
                        "interface_tags": interface_tags,
                    },
                    indent=2,
                    default=str,
                )
            )
            continue

        interface_tags[resolved_iface] = external
        available_tags = set(interface_tags.values())

    for tenant in required_tenants:
        if tenant not in available_tags:
            print(
                "WARNING: tenant cannot be mapped to any policy interface tag:\n"
                + json.dumps(
                    {
                        "tenant": tenant,
                        "interface_tags": interface_tags,
                        "required_tenants": sorted(required_tenants),
                    },
                    indent=2,
                    default=str,
                )
            )

    for external in required_externals:
        if external not in available_tags:
            print(
                "WARNING: external cannot be mapped to any policy interface tag:\n"
                + json.dumps(
                    {
                        "external": external,
                        "interface_tags": interface_tags,
                        "required_externals": sorted(required_externals),
                    },
                    indent=2,
                    default=str,
                )
            )

    return interface_tags


def _build_policy_rules(contract: Dict[str, Any], known_tags: set[str]):
    rules = []

    traffic_types_raw = contract.get("trafficTypes") or []
    traffic_type_matches: Dict[str, List[Dict[str, Any]]] = {}
    if isinstance(traffic_types_raw, list):
        for obj in traffic_types_raw:
            if not isinstance(obj, dict):
                continue
            name = obj.get("name")
            matches = obj.get("match")
            if not isinstance(name, str) or not name:
                continue
            if not isinstance(matches, list):
                continue
            traffic_type_matches[name] = [m for m in matches if isinstance(m, dict)]

    for relation in _relation_objects(contract):
        src_members = _members(relation.get("from"))
        dst = relation.get("to")

        if dst == "any":
            dst_members = sorted(known_tags)
        else:
            dst_members = _members(dst)

        action = "accept" if relation.get("action") == "allow" else "drop"
        matches = relation.get("match") or relation.get("matches") or []

        # Modern contracts can refer to trafficTypes by name instead of embedding
        # `match` directly inside each allowedRelation.
        if matches == []:
            tt = relation.get("trafficType")
            if isinstance(tt, str) and tt:
                if tt == "any":
                    matches = [{"family": "any", "proto": "any", "dports": []}]
                elif tt in traffic_type_matches:
                    matches = traffic_type_matches[tt]
                else:
                    raise RuntimeError(
                        "communicationContract.allowedRelations references unknown trafficType\n"
                        + json.dumps(
                            {
                                "trafficType": tt,
                                "knownTrafficTypes": sorted(traffic_type_matches.keys()),
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


def build_policy_firewall_state(site: SiteModel, policy_node_name: str, eth_map: Dict[str, int]):
    contract = dict(site.raw_policy or {})

    tenants = set(_contract_tenant_names(contract))
    externals = set(_contract_external_names(contract))

    interface_tags = _build_policy_interface_tags(
        site,
        policy_node_name,
        eth_map,
        tenants,
        externals,
    )

    rules = _build_policy_rules(contract, set(interface_tags.values()))

    return {
        "interface_tags": interface_tags,
        "rules": rules,
    }


def build_node_firewall_state(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
):
    if node.role == "policy":
        return {
            "policy_firewall_state": build_policy_firewall_state(
                site,
                node_name,
                eth_map,
            )
        }

    return {}
