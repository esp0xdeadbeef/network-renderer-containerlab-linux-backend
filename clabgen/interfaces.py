from typing import Dict, Any, List


def _is_virtual_interface(iface: Dict[str, Any]) -> bool:
    return bool(
        iface.get("virtual") is True
        or iface.get("logical") is True
        or iface.get("kind") == "tenant"
        or iface.get("type") == "logical"
        or iface.get("carrier") == "logical"
    )


def render_interfaces(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    interfaces = node.get("interfaces", {})

    for logical_if in sorted(interfaces.keys()):
        iface = interfaces[logical_if]
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        if _is_virtual_interface(iface):
            cmds.append(f"ip link show {eth} >/dev/null 2>&1 || ip link add {eth} type dummy")

        # bring interface up (no per-if sysctl; global rp_filter loop already rendered)
        cmds.append(f"ip link set {eth} up")

    return cmds
