from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List
import json

from clabgen.s88.CM.linux_bgp_state import (
    _collect_bgp_networks,
    _first_router_id,
    _is_bgp_router,
    _peer_ip,
    _peer_ip_sort_key,
)
from clabgen.s88.CM.linux_shell import _sh

RUNTIME_SCRIPT = Path(__file__).with_name("frr_bootstrap_runtime.py")


def _render_bgp(node_name: str, node: Dict[str, Any], role: str) -> List[str]:
    if not _is_bgp_router(role):
        return []

    bgp = node.get("bgp", {})
    if not isinstance(bgp, dict):
        return []

    asn = bgp.get("asn")
    if not isinstance(asn, int):
        return []

    neighbors = bgp.get("neighbors", [])
    if not isinstance(neighbors, list):
        neighbors = []

    ipv4_neighbors: List[Dict[str, Any]] = []
    ipv6_neighbors: List[Dict[str, Any]] = []

    for neighbor in neighbors:
        if not isinstance(neighbor, dict):
            continue

        peer_asn = neighbor.get("peer_asn")
        if not isinstance(peer_asn, int):
            continue

        update_source = neighbor.get("update_source")
        rr_client = bool(neighbor.get("route_reflector_client", False))

        peer_addr4 = _peer_ip(neighbor.get("peer_addr4"))
        peer_addr6 = _peer_ip(neighbor.get("peer_addr6"))

        if isinstance(peer_addr4, str):
            ipv4_neighbors.append(
                {
                    "peer_ip": peer_addr4,
                    "peer_asn": peer_asn,
                    "update_source": update_source,
                    "rr_client": rr_client,
                }
            )
        if isinstance(peer_addr6, str):
            ipv6_neighbors.append(
                {
                    "peer_ip": peer_addr6,
                    "peer_asn": peer_asn,
                    "update_source": update_source,
                    "rr_client": rr_client,
                }
            )

    unique_ipv4_neighbors: Dict[tuple[Any, ...], Dict[str, Any]] = {}
    for neighbor in ipv4_neighbors:
        neighbor_key = (
            neighbor["peer_ip"],
            neighbor["peer_asn"],
            neighbor.get("update_source"),
            neighbor["rr_client"],
        )
        unique_ipv4_neighbors[neighbor_key] = neighbor
    ipv4_neighbors = sorted(unique_ipv4_neighbors.values(), key=_peer_ip_sort_key)

    unique_ipv6_neighbors: Dict[tuple[Any, ...], Dict[str, Any]] = {}
    for neighbor in ipv6_neighbors:
        neighbor_key = (
            neighbor["peer_ip"],
            neighbor["peer_asn"],
            neighbor.get("update_source"),
            neighbor["rr_client"],
        )
        unique_ipv6_neighbors[neighbor_key] = neighbor
    ipv6_neighbors = sorted(unique_ipv6_neighbors.values(), key=_peer_ip_sort_key)

    networks4, networks6 = _collect_bgp_networks(node)
    router_id = _first_router_id(node)

    config_lines: List[str] = [
        "frr defaults traditional",
        f"hostname {node_name}",
        "service integrated-vtysh-config",
        "log stdout",
        "!",
        "ip forwarding",
        "ipv6 forwarding",
        "!",
        f"router bgp {asn}",
        f" bgp router-id {router_id}",
        " no bgp ebgp-requires-policy",
        " no bgp network import-check",
    ]

    for neighbor in ipv4_neighbors:
        peer_ip = neighbor["peer_ip"]
        peer_asn = neighbor["peer_asn"]
        config_lines.append(f" neighbor {peer_ip} remote-as {peer_asn}")
        if isinstance(neighbor.get("update_source"), str) and neighbor["update_source"]:
            config_lines.append(
                f" neighbor {peer_ip} update-source {neighbor['update_source']}"
            )

    for neighbor in ipv6_neighbors:
        peer_ip = neighbor["peer_ip"]
        peer_asn = neighbor["peer_asn"]
        config_lines.append(f" neighbor {peer_ip} remote-as {peer_asn}")
        if isinstance(neighbor.get("update_source"), str) and neighbor["update_source"]:
            config_lines.append(
                f" neighbor {peer_ip} update-source {neighbor['update_source']}"
            )

    config_lines.append(" !")
    config_lines.append(" address-family ipv4 unicast")
    for network in networks4:
        config_lines.append(f"  network {network}")
    for neighbor in ipv4_neighbors:
        config_lines.append(f"  neighbor {neighbor['peer_ip']} activate")
        if neighbor["rr_client"]:
            config_lines.append(
                f"  neighbor {neighbor['peer_ip']} route-reflector-client"
            )
    config_lines.append(" exit-address-family")
    config_lines.append(" !")
    config_lines.append(" address-family ipv6 unicast")
    for network in networks6:
        config_lines.append(f"  network {network}")
    for neighbor in ipv6_neighbors:
        config_lines.append(f"  neighbor {neighbor['peer_ip']} activate")
        if neighbor["rr_client"]:
            config_lines.append(
                f"  neighbor {neighbor['peer_ip']} route-reflector-client"
            )
    config_lines.append(" exit-address-family")
    config_lines.append("!")
    config_lines.append("line vty")
    config_lines.append("!")

    daemons = {
        "zebra": "yes",
        "bgpd": "yes",
        "ospfd": "no",
        "ospf6d": "no",
        "ripd": "no",
        "ripngd": "no",
        "isisd": "no",
        "pimd": "no",
        "pim6d": "no",
        "ldpd": "no",
        "nhrpd": "no",
        "eigrpd": "no",
        "babeld": "no",
        "sharpd": "no",
        "staticd": "yes",
        "bfdd": "no",
        "fabricd": "no",
        "vrrpd": "no",
        "pathd": "no",
    }

    payload = {
        "daemons": daemons,
        "frr_conf": "\n".join(config_lines) + "\n",
        "vtysh_conf": "service integrated-vtysh-config\n",
    }

    payload_json = json.dumps(payload, indent=2, sort_keys=True)
    bootstrap_script = RUNTIME_SCRIPT.read_text()

    return [
        _sh("mkdir -p /var/run/frr /etc/frr"),
        _sh("touch /etc/frr/daemons /etc/frr/frr.conf /etc/frr/vtysh.conf"),
        _sh(
            "cat >/tmp/clabgen-frr-bootstrap.json <<'JSON'\n"
            + payload_json
            + "\nJSON\n"
            + "cat >/tmp/clabgen-frr-bootstrap.py <<'PY'\n"
            + bootstrap_script
            + "PY\n"
            + "python3 /tmp/clabgen-frr-bootstrap.py /tmp/clabgen-frr-bootstrap.json\n"
        ),
    ]
