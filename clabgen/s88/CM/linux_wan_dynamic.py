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

    client_ip = ipv4.get("clientAddress")
    if not isinstance(client_ip, str) or not client_ip:
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


def _artifact_live_vlan(artifact: Dict[str, Any]) -> int | None:
    live = artifact.get("liveUpstreamReachability")
    if isinstance(live, dict):
        vlan = live.get("vlan")
        if isinstance(vlan, int) and not isinstance(vlan, bool):
            return vlan
    vlan = artifact.get("liveUpstreamVlan")
    if isinstance(vlan, int) and not isinstance(vlan, bool):
        return vlan
    return None


def _fake_provider_commands(
    interface_name: str,
    host_uplink: Dict[str, Any],
    artifacts: Any,
) -> List[str]:
    vlan = host_uplink.get("vlan")
    if isinstance(vlan, bool) or not isinstance(vlan, int):
        return []
    if not isinstance(artifacts, list):
        return []

    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        if artifact.get("providerEmulationMode") != "fake-provider":
            continue
        if _artifact_live_vlan(artifact) != vlan:
            continue

        dhcp4 = artifact.get("dhcp4")
        if not isinstance(dhcp4, dict):
            raise ValueError(
                "fake-provider WAN binding requires dhcp4 data for "
                f"VLAN {vlan}"
            )
        address = dhcp4.get("address")
        router = dhcp4.get("router")
        client_address = dhcp4.get("clientAddress")
        if not all(isinstance(value, str) and value for value in (address, router, client_address)):
            raise ValueError(
                "fake-provider WAN binding requires dhcp4.address, "
                f"dhcp4.router, and dhcp4.clientAddress for VLAN {vlan}"
            )

        try:
            provider = ipaddress.ip_interface(address)
            client = ipaddress.ip_address(client_address)
            router_ip = ipaddress.ip_address(router)
        except ValueError as exc:
            raise ValueError(
                f"fake-provider WAN binding has invalid IPv4 data for VLAN {vlan}"
            ) from exc
        if provider.version != 4 or client.version != 4 or router_ip.version != 4:
            raise ValueError(
                f"fake-provider WAN binding requires IPv4 data for VLAN {vlan}"
            )
        if client not in provider.network or router_ip not in provider.network:
            raise ValueError(
                f"fake-provider WAN binding client/router not in provider subnet for VLAN {vlan}"
            )

        return [
            f"ip addr flush dev {interface_name}",
            f"ip addr replace {client_address}/{provider.network.prefixlen} dev {interface_name}",
            f"ip route replace default via {router} dev {interface_name} onlink",
        ]

    return []


def render(node: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []
    lab_emulation_artifacts = node.get("labEmulationArtifacts")

    wan_ifaces = _wan_interfaces(node, eth_map)
    for interface_data in wan_ifaces:
        interface_name = interface_data["name"]
        host_uplink = interface_data["host_uplink"]
        cmds.append(_sh(_slaac_command(interface_name)))
        if isinstance(host_uplink, dict) and host_uplink:
            # CPM provided hostUplink data. Address assignment mode comes from
            # ipv4.method/ipv6.method; NAT remains an explicit top-level mode.
            # Trace: FS-380-HDS-010-SDS-010-SMS-060 (core WAN IP assignment).
            uplink_mode = host_uplink.get("mode")
            ipv4_method = (host_uplink.get("ipv4") or {}).get("method")
            ipv6_method = (host_uplink.get("ipv6") or {}).get("method")
            host_mode = ipv4_method or ipv6_method
            fake_provider_commands = (
                _fake_provider_commands(
                    interface_name, host_uplink, lab_emulation_artifacts
                )
                if host_mode == "dhcp"
                else []
            )
            if fake_provider_commands:
                for command in fake_provider_commands:
                    cmds.append(_sh(command))
            elif host_mode == "static" and uplink_mode == "nat":
                for command in _nat4_commands(interface_name, host_uplink):
                    cmds.append(_sh(command))
            elif host_mode == "static":
                pass
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
