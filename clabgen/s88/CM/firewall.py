from __future__ import annotations

from typing import Any, Dict, Iterable, List, Tuple


def _iter_site_dicts(enterprise: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    for enterprise_obj in enterprise.values():
        if not isinstance(enterprise_obj, dict):
            continue
        site_root = enterprise_obj.get("site")
        if not isinstance(site_root, dict):
            continue
        for site_obj in site_root.values():
            if isinstance(site_obj, dict):
                yield site_obj


def _load_site_context(node_data: Dict[str, Any]) -> Dict[str, Any]:
    enterprise = node_data.get("enterprise")
    if not isinstance(enterprise, dict):
        raise RuntimeError("missing node_data['enterprise']")

    for site_obj in _iter_site_dicts(enterprise):
        return site_obj

    raise RuntimeError("missing site context")


def _load_contract(node_data: Dict[str, Any]) -> Dict[str, Any]:
    site_obj = _load_site_context(node_data)
    contract = site_obj.get("communicationContract")
    if not isinstance(contract, dict):
        raise RuntimeError("missing communicationContract")
    return contract


def _site_topology(node_data: Dict[str, Any]) -> Dict[str, Any]:
    topology = node_data.get("site_topology")
    if not isinstance(topology, dict):
        raise RuntimeError("missing site_topology")
    return topology


def _topology_nodes(node_data: Dict[str, Any]) -> Dict[str, Any]:
    nodes = _site_topology(node_data).get("nodes")
    if not isinstance(nodes, dict):
        raise RuntimeError("site_topology.nodes must be an object")
    return nodes


def _topology_links(node_data: Dict[str, Any]) -> Dict[str, Any]:
    links = _site_topology(node_data).get("links")
    if not isinstance(links, dict):
        raise RuntimeError("site_topology.links must be an object")
    return links


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


def _contract_tenant_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()

    for relation in _relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if not isinstance(endpoint, dict):
                continue
            if endpoint.get("kind") in {"tenant", "tenant-set"}:
                result.update(_members(endpoint))

    return sorted(result)


def _contract_external_names(contract: Dict[str, Any]) -> List[str]:
    result: set[str] = set()

    for relation in _relation_objects(contract):
        for side in ("from", "to"):
            endpoint = relation.get(side)
            if not isinstance(endpoint, dict):
                continue
            if endpoint.get("kind") == "external":
                result.update(_members(endpoint))

    return sorted(result)


def _s88_ifname_to_eth(node_data: Dict[str, Any]) -> Dict[str, int]:
    parsed = node_data.get("_s88_links")
    if not isinstance(parsed, dict):
        raise RuntimeError("missing _s88_links")

    links = parsed.get("links")
    if not isinstance(links, dict):
        raise RuntimeError("missing _s88_links.links")

    all_links = links.get("all")
    if not isinstance(all_links, list):
        raise RuntimeError("missing _s88_links.links.all")

    result: Dict[str, int] = {}
    for item in all_links:
        if not isinstance(item, dict):
            continue
        ifname = item.get("ifname")
        eth = item.get("eth")
        if isinstance(ifname, str) and isinstance(eth, int):
            result[ifname] = eth

    return result


def _policy_link_peers(node_name: str, node_data: Dict[str, Any]) -> List[Tuple[int, str]]:
    ifname_to_eth = _s88_ifname_to_eth(node_data)
    results: List[Tuple[int, str]] = []

    for _, link in sorted(_topology_links(node_data).items()):
        if not isinstance(link, dict):
            continue

        endpoints = link.get("endpoints")
        if not isinstance(endpoints, dict):
            continue

        local = endpoints.get(node_name)
        if not isinstance(local, dict):
            continue

        local_ifname = local.get("interface")
        if not isinstance(local_ifname, str):
            raise RuntimeError("policy endpoint missing interface")

        eth = ifname_to_eth.get(local_ifname)
        if eth is None:
            raise RuntimeError(f"missing eth mapping for {local_ifname}")

        peers = [n for n in endpoints.keys() if n != node_name]
        if len(peers) != 1:
            raise RuntimeError("policy link must have exactly one peer")

        results.append((eth, peers[0]))

    return results


def _access_node_tenant_zone(access_node_name: str, node_data: Dict[str, Any]) -> str:
    topology_nodes = _topology_nodes(node_data)
    access_node = topology_nodes.get(access_node_name)
    if not isinstance(access_node, dict):
        raise RuntimeError(f"missing topology node {access_node_name!r}")

    if access_node.get("role") != "access":
        raise RuntimeError(
            f"policy access link peer {access_node_name!r} is not an access node"
        )

    interfaces = access_node.get("interfaces")
    if not isinstance(interfaces, dict):
        raise RuntimeError("access node interfaces missing")

    tenant_zones: set[str] = set()

    for ifname, iface in interfaces.items():
        if not isinstance(iface, dict):
            continue

        if iface.get("kind") != "tenant":
            continue

        tenant_name = iface.get("tenant")

        if not isinstance(tenant_name, str):
            network = iface.get("network")
            if isinstance(network, dict):
                tenant_name = network.get("name")

        if not isinstance(tenant_name, str) and isinstance(ifname, str):
            if ifname.startswith("tenant-"):
                tenant_name = ifname.split("tenant-")[1]

        if isinstance(tenant_name, str):
            tenant_zones.add(tenant_name)

    if not tenant_zones:
        raise RuntimeError(
            f"tenant zone cannot be resolved for access node {access_node_name!r}. "
            f"Interfaces seen: {list(interfaces.keys())}"
        )

    if len(tenant_zones) != 1:
        raise RuntimeError(
            f"multiple tenant zones on access node {access_node_name!r}: {sorted(tenant_zones)}"
        )

    return next(iter(tenant_zones))


def _build_zone_map(node_name: str, node_data: Dict[str, Any]) -> Dict[str, str]:
    contract = _load_contract(node_data)

    required_tenants = set(_contract_tenant_names(contract))
    required_externals = set(_contract_external_names(contract))

    print("[FW DEBUG] tenants from contract:", sorted(required_tenants))
    print("[FW DEBUG] externals from contract:", sorted(required_externals))

    topology_nodes = _topology_nodes(node_data)

    zones: Dict[str, str] = {}
    wan_if: str | None = None

    for eth, peer_name in _policy_link_peers(node_name, node_data):
        peer = topology_nodes.get(peer_name)
        if not isinstance(peer, dict):
            raise RuntimeError(f"missing topology node {peer_name!r}")

        role = peer.get("role")
        iface = f"eth{eth}"

        if role == "access":
            tenant_zone = _access_node_tenant_zone(peer_name, node_data)
            print(f"[FW DEBUG] access node {peer_name} → tenant {tenant_zone} → {iface}")

            if tenant_zone in zones and zones[tenant_zone] != iface:
                raise RuntimeError(
                    f"multiple policy interfaces resolve to tenant zone {tenant_zone}"
                )

            zones[tenant_zone] = iface
            continue

        if role == "upstream-selector":
            if wan_if is not None and wan_if != iface:
                raise RuntimeError("multiple WAN interfaces detected")

            wan_if = iface
            print(f"[FW DEBUG] upstream-selector {peer_name} → wan → {iface}")
            continue

    if wan_if is None:
        raise RuntimeError("wan cannot be resolved from topology")

    zones["wan"] = wan_if

    print("[FW DEBUG] final zone map:", zones)

    for tenant in required_tenants:
        if tenant not in zones:
            raise RuntimeError(
                f"tenant zone {tenant} cannot be mapped to a policy interface"
            )

    for external in required_externals:
        if external != "wan":
            raise RuntimeError(
                f"external zone {external} cannot be mapped from topology"
            )

    return zones


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


def render(role: str, node_name: str, node_data: Dict[str, Any]) -> List[str]:
    if role != "policy":
        return []

    contract = _load_contract(node_data)
    zones = _build_zone_map(node_name, node_data)
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

        # handle "any"
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
