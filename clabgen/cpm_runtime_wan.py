from __future__ import annotations

from typing import Any, Dict


def _dict_value(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string_value(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def wan_link(
    node_name: str,
    if_key: str,
    iface: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    host_uplink = _dict_value(iface.get("hostUplink")) or _dict_value(
        link_host_uplinks.get(if_key)
    )
    bridge = (
        _string_value(iface.get("attachBridge"))
        or _string_value(link_bridges.get(if_key))
        or _string_value(host_uplink.get("bridge"))
    )

    return {
        "kind": "wan",
        "bridge": bridge,
        "hostUplink": host_uplink,
        "endpoints": {
            node_name: {
                "node": node_name,
                "interface": if_key,
                "upstream": iface.get("upstream"),
                "uplink": iface.get("upstream"),
                "peerAddr4": None,
                "peerAddr6": None,
            }
        },
    }
