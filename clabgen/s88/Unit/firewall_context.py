from __future__ import annotations

from typing import Any, Dict, List
import json

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
            }
        )

    return results


def _access_node_tenants(node: NodeModel) -> List[str]:
    tenants: set[str] = set()

    for iface in node.interfaces.values():
        if getattr(iface, "kind", None) != "tenant":
            continue
        tenant = getattr(iface, "tenant", None)
        if isinstance(tenant, str) and tenant:
            tenants.add(tenant)

    if not tenants:
        debug = {
            "node": node.name,
            "role": node.role,
            "interfaces": {
                name: getattr(iface, "__dict__", str(iface))
                for name, iface in node.interfaces.items()
            },
        }

        raise RuntimeError(
            "tenant cannot be resolved for access node\n"
            + json.dumps(debug, indent=2, default=str)
        )

    return sorted(tenants)


def _build_policy_interface_tags(
    site: SiteModel,
    policy_node_name: str,
    eth_map: Dict[str, int],
    required_tenants: set[str],
    required_externals: set[str],
) -> Dict[str, str]:
    interface_tags: Dict[str, str] = {}
    peer_map = _policy_peer_map(site, policy_node_name, eth_map)

    for peer in peer_map:
        peer_node = site.nodes.get(peer["peer_name"])

        if peer_node is None:
            raise RuntimeError(
                f"peer node missing: {peer['peer_name']}\n"
                + json.dumps(sorted(site.nodes.keys()), indent=2, default=str)
            )

        iface_name = f"eth{peer['eth']}"

        if peer_node.role == "access":
            tenants = _access_node_tenants(peer_node)
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

    for tenant in required_tenants:
        if tenant not in available_tags:
            raise RuntimeError(
                f"tenant {tenant!r} cannot be mapped to any policy interface tag\n"
                + json.dumps(
                    {
                        "interface_tags": interface_tags,
                        "required_tenants": sorted(required_tenants),
                    },
                    indent=2,
                    default=str,
                )
            )

    for external in required_externals:
        if external not in available_tags:
            raise RuntimeError(
                f"external {external!r} cannot be mapped to any policy interface tag\n"
                + json.dumps(
                    {
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

    for relation in _relation_objects(contract):
        src_members = _members(relation.get("from"))
        dst = relation.get("to")

        if dst == "any":
            dst_members = sorted(known_tags)
        else:
            dst_members = _members(dst)

        action = "accept" if relation.get("action") == "allow" else "drop"
        matches = relation.get("match") or []

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
