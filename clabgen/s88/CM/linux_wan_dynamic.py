from __future__ import annotations

import ipaddress
from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh

# Global WAN index counter — persists across render() calls so each
# container gets a unique static IP from the VLAN4 pool.
_wan_global_index = 0


def _wan_interfaces(
    node: Dict[str, Any], eth_map: Dict[str, str]
) -> List[Dict[str, Any]]:
    interfaces = node.get("interfaces", {})
    if not isinstance(interfaces, dict):
        return []
    pppoe = node.get("services", {}).get("pppoe", {})
    if not isinstance(pppoe, dict):
        pppoe = {}
    pppoe_interfaces = set()
    for side in ("client", "server"):
        service = pppoe.get(side)
        if not isinstance(service, dict):
            continue
        logical = service.get("interface")
        if isinstance(logical, str) and logical:
            pppoe_interfaces.add(logical)

    wan_interfaces: List[Dict[str, Any]] = []
    for logical_name in sorted(interfaces.keys()):
        iface = interfaces[logical_name]
        if not isinstance(iface, dict):
            continue
        if iface.get("kind") != "wan":
            continue
        if logical_name in pppoe_interfaces:
            continue
        target_ifname = eth_map.get(logical_name)
        if target_ifname is None:
            continue
        wan_interfaces.append(
            {
                "logical_name": logical_name,
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


def _static_wan4_commands(
    interface_name: str, host_uplink: Dict[str, Any], wan_index: int, pool_base: str = "10.11.0"
) -> List[str]:
    """Generate static IP commands for WAN interfaces when DHCP is unreliable.
    
    Assigns deterministic IPs from the VLAN4 pool: 10.11.0.(100 + wan_index)/24
    with gateway 10.11.0.1. This avoids dependence on the systemd-networkd DHCP
    server which can fail silently after Containerlab redeploys.
    """
    octets = pool_base.split(".")
    if len(octets) != 3:
        return [_dhcp4_command(interface_name)]
    try:
        base = int(octets[2])
    except (ValueError, IndexError):
        return [_dhcp4_command(interface_name)]
    client_octet = 100 + wan_index
    if client_octet > 254:
        return [_dhcp4_command(interface_name)]
    client_ip = f"{octets[0]}.{octets[1]}.{base}.{client_octet}"
    gateway_ip = f"{octets[0]}.{octets[1]}.{base}.1"
    return [
        _sh(f"ip addr replace {client_ip}/24 dev {interface_name}"),
        _sh(f"ip route replace default via {gateway_ip} dev {interface_name} onlink"),
    ]


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
    global _wan_global_index
    cmds: List[str] = []

    wan_ifaces = _wan_interfaces(node, eth_map)
    for interface_data in wan_ifaces:
        interface_name = interface_data["name"]
        host_uplink = interface_data["host_uplink"]
        cmds.append(_sh(_slaac_command(interface_name)))
        if isinstance(host_uplink, dict) and host_uplink.get("mode") == "nat":
            for command in _nat4_commands(interface_name, host_uplink):
                cmds.append(_sh(command))
        else:
            # Use static IPs instead of DHCP — systemd-networkd DHCPServer
            # is unreliable across Containerlab redeploys and silently ignores
            # new DHCP DISCOVER requests after a fresh render-live cycle.
            cmds.extend(_static_wan4_commands(interface_name, host_uplink, _wan_global_index))
            _wan_global_index += 1

    return cmds
