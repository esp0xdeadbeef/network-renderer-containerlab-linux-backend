from __future__ import annotations

import ipaddress
from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh


def _wan_interfaces(
    node: Dict[str, Any], eth_map: Dict[str, str]
) -> List[Dict[str, Any]]:
    interfaces = node.get("interfaces", {})
    if not isinstance(interfaces, dict):
        return []

    wan_interfaces: List[Dict[str, Any]] = []
    for logical_name in sorted(interfaces.keys()):
        iface = interfaces[logical_name]
        if not isinstance(iface, dict):
            continue
        if iface.get("kind") != "wan":
            continue
        target_ifname = eth_map.get(logical_name)
        if target_ifname is None:
            continue
        wan_interfaces.append(
            {
                "name": target_ifname,
                "host_uplink": iface.get("hostUplink") or {},
            }
        )

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


def _nat4_commands(interface_name: str, host_uplink: Dict[str, Any]) -> List[str]:
    ipv4 = host_uplink.get("ipv4")
    if not isinstance(ipv4, dict):
        return []

    address = ipv4.get("address")
    if not isinstance(address, str) or not address:
        return []

    try:
        gateway = ipaddress.ip_interface(address)
    except ValueError:
        return []

    network = gateway.network
    if gateway.ip.version != 4 or network.num_addresses < 4:
        return []

    client_ip = str(ipv4.get("clientAddress") or network[2])
    prefixlen = gateway.network.prefixlen
    gateway_ip = str(gateway.ip)
    return [
        f"ip addr replace {client_ip}/{prefixlen} dev {interface_name}",
        f"ip route replace default via {gateway_ip} dev {interface_name} onlink",
    ]


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    for interface_data in _wan_interfaces(node, eth_map):
        interface_name = interface_data["name"]
        host_uplink = interface_data["host_uplink"]
        cmds.append(_sh(_slaac_command(interface_name)))
        if isinstance(host_uplink, dict) and host_uplink.get("mode") == "nat":
            for command in _nat4_commands(interface_name, host_uplink):
                cmds.append(_sh(command))
        else:
            cmds.append(_sh(_dhcp4_command(interface_name)))

    return cmds
