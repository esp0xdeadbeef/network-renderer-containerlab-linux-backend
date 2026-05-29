from __future__ import annotations

from typing import Dict, Any, List, Tuple


def _target_ifname(item: Tuple[str, str]) -> str:
    return item[1]


def _sorted_ifaces(eth_map: Dict[str, str]) -> List[Tuple[str, str]]:
    return sorted(eth_map.items(), key=_target_ifname)


def _link(ifname: str, target_ifname: str) -> Dict[str, Any]:
    return {
        "ifname": ifname,
        "targetIfName": target_ifname,
    }


def _maybe_link(items: List[Tuple[str, str]], index: int) -> Dict[str, Any] | None:
    if index < 0:
        index = len(items) + index
    if index < 0 or index >= len(items):
        return None
    ifname, target_ifname = items[index]
    return _link(ifname, target_ifname)


def _links(items: List[Tuple[str, str]]) -> List[Dict[str, Any]]:
    links: List[Dict[str, Any]] = []
    for ifname, target_ifname in items:
        links.append(_link(ifname, target_ifname))
    return links


def parse_access(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    return {
        "node": node_name,
        "role": "access",
        "links": {
            "fabric": _maybe_link(items, 0),
            "tenant": _maybe_link(items, 1),
            "all": _links(items),
        },
    }


def parse_core(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    return {
        "node": node_name,
        "role": "core",
        "links": {
            "fabric": _maybe_link(items, 0),
            "wan": _maybe_link(items, 1),
            "all": _links(items),
        },
    }


def parse_wan_peer(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    return {
        "node": node_name,
        "role": "wan-peer",
        "links": {
            "fabric": _maybe_link(items, 0),
            "all": _links(items),
        },
    }


def parse_upstream_selector(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    return {
        "node": node_name,
        "role": "upstream-selector",
        "links": {
            "cores": _links(items[:-1]) if len(items) > 1 else [],
            "policy": _maybe_link(items, -1),
            "all": _links(items),
        },
    }


def parse_downstream_selector(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    # By convention: a downstream-selector has multiple access-facing links and one policy-facing link.
    return {
        "node": node_name,
        "role": "downstream-selector",
        "links": {
            "policy": _maybe_link(items, 0),
            "accesses": _links(items[1:]) if len(items) > 1 else [],
            "all": _links(items),
        },
    }


def parse_policy(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> Dict[str, Any]:
    _ = node_data
    items = _sorted_ifaces(eth_map)

    return {
        "node": node_name,
        "role": "policy",
        "links": {
            "accesses": _links(items[:-1]) if len(items) > 1 else [],
            "upstream_selector": _maybe_link(items, -1),
            "all": _links(items),
        },
    }
