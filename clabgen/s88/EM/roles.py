from __future__ import annotations

from typing import Dict, Any, List, Tuple


def _sorted_ifaces(eth_map: Dict[str, int]) -> List[Tuple[str, int]]:
    return sorted(eth_map.items(), key=lambda x: x[1])


def _link(ifname: str, eth: int) -> Dict[str, Any]:
    return {
        "ifname": ifname,
        "eth": eth,
    }


def _maybe_link(items: List[Tuple[str, int]], index: int) -> Dict[str, Any] | None:
    if index < 0:
        index = len(items) + index
    if index < 0 or index >= len(items):
        return None
    ifname, eth = items[index]
    return _link(ifname, eth)


def _links(items: List[Tuple[str, int]]) -> List[Dict[str, Any]]:
    return [_link(ifname, eth) for ifname, eth in items]


def parse_access(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
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
    eth_map: Dict[str, int],
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
    eth_map: Dict[str, int],
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
    eth_map: Dict[str, int],
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


def parse_policy(
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
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
