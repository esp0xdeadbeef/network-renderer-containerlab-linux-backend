# ./clabgen/interfaces.py
from typing import Dict, Any, List


def render_interfaces(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    interfaces = node.get("interfaces", {})

    for logical_if, iface in interfaces.items():
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        # bring interface up (no per-if sysctl; global rp_filter loop already rendered)
        cmds.append(f"ip link set {eth} up")

    return cmds
