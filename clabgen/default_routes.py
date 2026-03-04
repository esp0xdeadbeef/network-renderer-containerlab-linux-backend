# ./clabgen/default_routes.py
from __future__ import annotations

from typing import Dict, Any, List


def render_default_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    """
    Render default routes directly from solver-declared routes.

    The solver JSON already contains explicit default routes in:
      interface.routes4 / interface.routes6

    Example:
      {"dst":"0.0.0.0/0","via4":"10.10.0.1"}
      {"dst":"::/0","via6":"fd42:dead:beef:1000::1"}

    This function translates those declarations into containerlab exec commands.
    """

    cmds: List[str] = []

    interfaces = node.get("interfaces", {}) or {}

    for logical_if, iface in interfaces.items():
        eth = eth_map.get(logical_if)
        if eth is None or eth < 1:
            continue

        routes4 = iface.get("routes4", []) or []
        for r in routes4:
            if not isinstance(r, dict):
                continue

            dst = r.get("dst")
            via4 = r.get("via4")

            if dst in ("0.0.0.0/0", "default"):
                if via4:
                    cmds.append(f"ip route replace default via {via4} dev eth{eth}")
                else:
                    cmds.append(f"ip route replace default dev eth{eth}")

        routes6 = iface.get("routes6", []) or []
        for r in routes6:
            if not isinstance(r, dict):
                continue

            dst = r.get("dst")
            via6 = r.get("via6")

            if dst in ("::/0", "default"):
                if via6:
                    cmds.append(f"ip -6 route replace default via {via6} dev eth{eth}")
                else:
                    cmds.append(f"ip -6 route replace default dev eth{eth}")

    return cmds
