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

    client_ip = str(ipv4.get("clientAddress"))
    if not client_ip:
        raise ValueError(
            "CLAB WAN NAT requires clientAddress in hostUplink.ipv4. "
            "CPM must provide the client address for NAT mode interfaces. "
            "CPM_GAP: no clientAddress field in current CPM hostUplink contract."
        )
    prefixlen = gateway.network.prefixlen
    gateway_ip = str(gateway.ip)
    return [
        f"ip addr replace {client_ip}/{prefixlen} dev {interface_name}",
        f"ip route replace default via {gateway_ip} dev {interface_name} onlink",
    ]


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []

    wan_ifaces = _wan_interfaces(node, eth_map)
    for interface_data in wan_ifaces:
        interface_name = interface_data["name"]
        host_uplink = interface_data["host_uplink"]
        cmds.append(_sh(_slaac_command(interface_name)))
        if isinstance(host_uplink, dict) and host_uplink:
            # CPM provided hostUplink data — derive mode from ipv4.method/ipv6.method
            # CPM emits hostUplink with ipv4.method/ipv6.method, not a top-level 'mode'.
            # Trace: FS-380-HDS-010-SDS-010-SMS-060 (core WAN IP assignment).
            ipv4_method = (host_uplink.get("ipv4") or {}).get("method")
            ipv6_method = (host_uplink.get("ipv6") or {}).get("method")
            host_mode = ipv4_method or ipv6_method
            if host_mode == "static":
                for command in _nat4_commands(interface_name, host_uplink):
                    cmds.append(_sh(command))
            elif host_mode in ("dhcp", None):
                cmds.append(_sh(_dhcp4_command(interface_name)))
            else:
                # Unknown method — treat as DHCP (legacy)
                cmds.append(_sh(_dhcp4_command(interface_name)))
        else:
            # CPM_GAP: no hostUplink data — fall back to DHCP (legacy behavior,
            # pending CPM hostUplink contract completion).
            # Trace: FS-380-HDS-010-SDS-010-SMS-060 (core WAN IP assignment).
            cmds.append(_sh(_dhcp4_command(interface_name)))

    return cmds
