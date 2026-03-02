from typing import Dict, Any, List
import ipaddress


def render_connected_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    interfaces = node.get("interfaces", {})

    for logical_if, iface in interfaces.items():
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        addr4 = iface.get("addr4")
        if addr4:
            net4 = str(ipaddress.ip_interface(addr4).network)
            cmds.append(f"ip route replace {net4} dev {eth} scope link")

        addr6 = iface.get("addr6")
        if addr6:
            net6 = str(ipaddress.ip_interface(addr6).network)
            cmds.append(f"ip -6 route replace {net6} dev {eth}")

    return cmds
