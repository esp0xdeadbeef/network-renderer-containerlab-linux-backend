from __future__ import annotations

from typing import Any, Dict, List

from .roles import (
    parse_access,
    parse_core,
    parse_policy,
    parse_upstream_selector,
    parse_wan_peer,
)

from .default import render as render_default


def _parse(role: str, node_name: str, node_data: Dict[str, Any], eth_map: Dict[str, int]) -> Dict[str, Any]:
    r = str(role or "").strip()

    if r == "access":
        return parse_access(node_name, node_data, eth_map)

    if r == "core":
        return parse_core(node_name, node_data, eth_map)

    if r == "policy":
        return parse_policy(node_name, node_data, eth_map)

    if r == "upstream-selector":
        return parse_upstream_selector(node_name, node_data, eth_map)

    if r == "wan-peer":
        return parse_wan_peer(node_name, node_data, eth_map)

    return {"node": node_name, "role": r, "links": {}}


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
    routing_mode: str = "static",
    disable_dynamic: bool = True,
) -> List[str]:
    _ = routing_mode
    _ = disable_dynamic

    parsed = _parse(role, node_name, node_data, eth_map)
    node_data["_s88_links"] = parsed

    return render_default(role, node_name, node_data, eth_map)
