from __future__ import annotations

from typing import Any, Dict, List
import ipaddress
import re
import shlex

from clabgen.s88.site.naming import host_ifname


def _slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return slug or "unnamed"


def _sh(command: str) -> str:
    return "sh -c " + shlex.quote(command)


def _live_vlan(artifact: Dict[str, Any]) -> int | None:
    live = artifact.get("liveUpstreamReachability")
    if isinstance(live, dict):
        vlan = live.get("vlan")
        if isinstance(vlan, int) and not isinstance(vlan, bool):
            return vlan
    vlan = artifact.get("liveUpstreamVlan")
    if isinstance(vlan, int) and not isinstance(vlan, bool):
        return vlan
    return None


def _bridge_for_vlan(bridge_networks: Dict[str, Any], vlan: int) -> str | None:
    for key, value in sorted(bridge_networks.items()):
        if not isinstance(value, dict):
            continue
        if value.get("mode") != "vlan" or value.get("vlan") != vlan:
            continue
        bridge = value.get("bridge")
        if isinstance(bridge, str) and bridge:
            return bridge
        if isinstance(key, str) and key:
            return key
    return None


def _required_string(mapping: Dict[str, Any], key: str, label: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"fake-provider lab-emulation runtime requires {label}.{key}")
    return value


def _dhcp_config_commands(name: str, dhcp4: Dict[str, Any], iface_name: str) -> List[str]:
    address = _required_string(dhcp4, "address", "dhcp4")
    router = _required_string(dhcp4, "router", "dhcp4")
    range_start = _required_string(dhcp4, "rangeStart", "dhcp4")
    range_end = _required_string(dhcp4, "rangeEnd", "dhcp4")
    source_prefix = _required_string(dhcp4, "sourcePrefix", "dhcp4")
    lease_time = _required_string(dhcp4, "leaseTime", "dhcp4")

    try:
        iface = ipaddress.ip_interface(address)
        prefix = ipaddress.ip_network(source_prefix, strict=False)
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime has invalid IPv4 DHCP data for {name}"
        ) from exc
    if iface.version != 4 or prefix.version != 4:
        raise ValueError(
            f"fake-provider lab-emulation runtime requires IPv4 DHCP data for {name}"
        )

    try:
        lease_seconds = (
            int(lease_time[:-1]) * 60
            if lease_time.endswith("m")
            else int(lease_time)
        )
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime leaseTime must be minutes or seconds for {name}"
        ) from exc

    netmask = str(prefix.netmask)
    config_lines = [
        f"start {range_start}",
        f"end {range_end}",
        f"interface {iface_name}",
        f"option subnet {netmask}",
        f"option router {router}",
        f"option lease {lease_seconds}",
        "lease_file /run/udhcpd/fake-provider.leases",
        "pidfile /run/udhcpd/fake-provider.pid",
    ]
    write_config_script = (
        "printf '%s\\n' "
        + " ".join(shlex.quote(line) for line in config_lines)
        + " > /run/udhcpd/fake-provider.conf"
    )
    write_config = "sh -c " + shlex.quote(write_config_script)
    return [
        "sysctl -w net.ipv4.ip_forward=1",
        f"ip addr replace {address} dev {iface_name}",
        f"ip link set {iface_name} up",
        "mkdir -p /run/udhcpd",
        write_config,
        "pkill -x udhcpd || true",
        "udhcpd /run/udhcpd/fake-provider.conf",
    ]


def _nat_commands(name: str, artifact: Dict[str, Any], dhcp4: Dict[str, Any]) -> List[str]:
    nat44 = artifact.get("nat44")
    if not isinstance(nat44, dict) or nat44.get("enabled") is not True:
        return []
    source_prefix = nat44.get("sourcePrefix") or dhcp4.get("sourcePrefix")
    if not isinstance(source_prefix, str) or not source_prefix:
        raise ValueError(
            f"fake-provider lab-emulation runtime NAT44 requires sourcePrefix for {name}"
        )
    try:
        prefix = ipaddress.ip_network(source_prefix, strict=False)
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime has invalid NAT44 sourcePrefix for {name}"
        ) from exc
    if prefix.version != 4:
        raise ValueError(
            f"fake-provider lab-emulation runtime NAT44 requires IPv4 sourcePrefix for {name}"
        )
    return [
        _sh(
            "\n".join(
                [
                    "set -e",
                    "nft add table ip nat 2>/dev/null || true",
                    'nft "add chain ip nat postrouting { type nat hook postrouting priority 100; policy accept; }" 2>/dev/null || true',
                    "nft flush chain ip nat postrouting",
                    f'nft add rule ip nat postrouting oifname "eth0" ip saddr {source_prefix} masquerade',
                    "nft list chain ip nat postrouting >/dev/null",
                ]
            )
        )
    ]


def render_lab_emulation_runtime(
    artifacts: List[Dict[str, Any]],
    bridge_networks: Dict[str, Any],
) -> Dict[str, Any]:
    nodes: Dict[str, Any] = {}
    links: List[Dict[str, Any]] = []
    bridges: List[str] = []

    for artifact in artifacts:
        if artifact.get("providerEmulationMode") != "fake-provider":
            continue
        dhcp4 = artifact.get("dhcp4")
        if not isinstance(dhcp4, dict):
            continue
        if artifact.get("scope") != "harness" or artifact.get("harnessScoped") is not True:
            raise ValueError("fake-provider lab-emulation runtime must be harness scoped")
        vlan = _live_vlan(artifact)
        if vlan is None:
            raise ValueError(
                "fake-provider lab-emulation runtime requires live upstream VLAN"
            )
        bridge = _bridge_for_vlan(bridge_networks, vlan)
        if bridge is None:
            raise ValueError(
                f"fake-provider lab-emulation runtime VLAN {vlan} has no rendered bridge network"
            )

        name = _slug(str(artifact.get("name") or "fake-provider"))
        node_name = f"lab-emulation-{name}"
        if node_name in nodes:
            raise ValueError(f"duplicate lab-emulation node {node_name!r}")
        provider_ifname = host_ifname(f"{node_name}-provider")

        exec_cmds = _dhcp_config_commands(name, dhcp4, provider_ifname) + _nat_commands(
            name, artifact, dhcp4
        )
        nodes[node_name] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
            "exec": exec_cmds,
            "labels": {
                "clab.lab-emulation": "fake-provider",
                "clab.lab-emulation.scope": "harness",
            },
        }
        links.append(
            {
                "endpoints": [
                    f"{node_name}:{provider_ifname}",
                    f"{bridge}:{host_ifname(f'{bridge}-{node_name}-{provider_ifname}')}",
                ],
                "labels": {
                    "clab.link.type": "lab-emulation",
                    "clab.link.bridge": bridge,
                },
            }
        )
        bridges.append(bridge)

    return {"nodes": nodes, "links": links, "bridges": bridges}
