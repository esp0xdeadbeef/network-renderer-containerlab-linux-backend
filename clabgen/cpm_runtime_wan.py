from __future__ import annotations

from typing import Any, Dict


def wan_link(
    node_name: str,
    if_key: str,
    iface: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    return {
        "kind": "wan",
        "bridge": iface.get("attachBridge") or link_bridges.get(if_key),
        "hostUplink": iface.get("hostUplink") or link_host_uplinks.get(if_key, {}),
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
