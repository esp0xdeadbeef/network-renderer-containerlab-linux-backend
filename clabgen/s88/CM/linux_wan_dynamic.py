from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh


def _wan_interfaces(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    interfaces = node.get("interfaces", {})
    if not isinstance(interfaces, dict):
        return []

    wan_interfaces: List[str] = []
    for logical_name in sorted(interfaces.keys()):
        iface = interfaces[logical_name]
        if not isinstance(iface, dict):
            continue
        if iface.get("kind") != "wan":
            continue
        eth_index = eth_map.get(logical_name)
        if eth_index is None:
            continue
        wan_interfaces.append(f"eth{eth_index}")

    return wan_interfaces


def _dhcp4_command(interface_name: str) -> str:
    pid_file = f"/run/udhcpc.{interface_name}.pid"
    return (
        f"test -x /sbin/udhcpc && udhcpc -b -i {interface_name} -p {pid_file} || true"
    )


def _slaac_command(interface_name: str) -> str:
    return (
        f"sysctl -qw net.ipv6.conf.{interface_name}.accept_ra=2 "
        f"net.ipv6.conf.{interface_name}.autoconf=1 "
        f"net.ipv6.conf.{interface_name}.disable_ipv6=0 "
        "|| true"
    )


def render(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for interface_name in _wan_interfaces(node, eth_map):
        cmds.append(_sh(_slaac_command(interface_name)))
        cmds.append(_sh(_dhcp4_command(interface_name)))

    return cmds
