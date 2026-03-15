from __future__ import annotations

from typing import Any, Dict, List
import ipaddress
import json

from clabgen.s88.CM.base import render as render_cm


_ROUTER_ROLES = {"access", "core", "policy", "upstream-selector", "wan-peer", "isp"}


def _is_virtual_interface(iface: Dict[str, Any]) -> bool:
    return bool(
        iface.get("virtual") is True
        or iface.get("logical") is True
        or iface.get("type") == "logical"
        or iface.get("carrier") == "logical"
    )


def _canon_v6(addr: str) -> str:
    try:
        return str(ipaddress.IPv6Interface(addr))
    except Exception:
        return addr


def _is_network_address(addr: str) -> bool:
    try:
        iface = ipaddress.ip_interface(addr)
    except Exception:
        return False
    return iface.ip == iface.network.network_address


def _first_usable_host(addr: str) -> str:
    iface = ipaddress.ip_interface(addr)
    net = iface.network

    if isinstance(net, ipaddress.IPv4Network):
        if net.prefixlen >= 31:
            return str(iface)
        hosts = net.hosts()
        first = next(hosts)
        return f"{first}/{net.prefixlen}"

    if net.prefixlen >= 127:
        return str(iface)

    hosts = net.hosts()
    first = next(hosts)
    return f"{first}/{net.prefixlen}"


def _normalize_l3_addr(addr: str, iface: Dict[str, Any]) -> str:
    if not isinstance(addr, str) or not addr:
        return addr

    if iface.get("kind") == "tenant" and _is_network_address(addr):
        return _first_usable_host(addr)

    return addr


def _p2p_peer(addr: str) -> str | None:
    try:
        iface = ipaddress.ip_interface(addr)
        net = iface.network
        ip = iface.ip

        if isinstance(net, ipaddress.IPv4Network) and net.prefixlen == 31:
            a, b = list(net)
            peer = b if ip == a else a
            return str(peer)

        if isinstance(net, ipaddress.IPv6Network) and net.prefixlen == 127:
            a, b = list(net)
            peer = b if ip == a else a
            return str(peer)

    except Exception:
        return None

    return None


def _route_lists(iface: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    routes = iface.get("routes")
    if routes is None:
        routes = {}
    if not isinstance(routes, dict):
        raise ValueError("interface.routes must be an object")

    ipv4 = routes.get("ipv4", [])
    ipv6 = routes.get("ipv6", [])

    if not isinstance(ipv4, list):
        raise ValueError("interface.routes.ipv4 must be an array")

    if not isinstance(ipv6, list):
        raise ValueError("interface.routes.ipv6 must be an array")

    return {
        "ipv4": [dict(r) for r in ipv4 if isinstance(r, dict)],
        "ipv6": [dict(r) for r in ipv6 if isinstance(r, dict)],
    }


def _dst(r: Dict[str, Any]) -> str | None:
    return r.get("dst")


def _via4(r: Dict[str, Any]) -> str | None:
    return r.get("via4")


def _via6(r: Dict[str, Any]) -> str | None:
    return r.get("via6")


def _normalize_prefix(dst: str) -> str:
    if not isinstance(dst, str):
        return dst

    if "." in dst and "/" in dst:
        ip, prefix = dst.split("/", 1)
        try:
            p = int(prefix)
            if p > 32:
                return f"{ip}/32"
        except Exception:
            pass

    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except Exception:
        return dst


def _addr_ip(addr: str | None) -> str | None:
    if not isinstance(addr, str) or not addr:
        return None
    try:
        return str(ipaddress.ip_interface(addr).ip)
    except Exception:
        return None


def _peer_in_subnet(cidr: str | None) -> str | None:
    if not isinstance(cidr, str) or not cidr:
        return None

    iface = ipaddress.ip_interface(cidr)
    current = iface.ip

    if isinstance(iface.network, ipaddress.IPv4Network):
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 31:
            candidates = list(iface.network)
    else:
        candidates = list(iface.network.hosts())
        if not candidates and iface.network.prefixlen == 127:
            candidates = list(iface.network)

    for cand in candidates:
        if cand != current:
            return str(cand)

    return None


def _conflicts_with_wan_peer(
    node: Dict[str, Any],
    ifname: str,
    addr: str | None,
) -> bool:
    ip = _addr_ip(addr)
    if ip is None:
        return False

    interfaces = node.get("interfaces", {}) or {}

    for other_ifname, other_iface in interfaces.items():
        if other_ifname == ifname:
            continue
        if not isinstance(other_iface, dict):
            continue
        if other_iface.get("kind") != "wan":
            continue

        peer4 = _peer_in_subnet(other_iface.get("addr4"))
        peer6 = _peer_in_subnet(other_iface.get("addr6"))

        if ip == peer4 or ip == peer6:
            return True

    return False


def _connected_prefixes(node: Dict[str, Any]) -> tuple[set[str], set[str]]:
    connected4: set[str] = set()
    connected6: set[str] = set()

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if isinstance(addr4, str) and addr4 and not _conflicts_with_wan_peer(node, ifname, addr4):
            try:
                connected4.add(str(ipaddress.ip_interface(addr4).network))
            except Exception:
                pass

        if isinstance(addr6, str) and addr6 and not _conflicts_with_wan_peer(node, ifname, addr6):
            try:
                connected6.add(str(ipaddress.ip_interface(addr6).network))
            except Exception:
                pass

    return connected4, connected6


def _local_ips(node: Dict[str, Any]) -> tuple[set[str], set[str]]:
    local4: set[str] = set()
    local6: set[str] = set()

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if isinstance(addr4, str) and addr4 and not _conflicts_with_wan_peer(node, ifname, addr4):
            try:
                local4.add(str(ipaddress.ip_interface(_normalize_l3_addr(addr4, iface)).ip))
            except Exception:
                pass

        if isinstance(addr6, str) and addr6 and not _conflicts_with_wan_peer(node, ifname, addr6):
            try:
                local6.add(str(ipaddress.ip_interface(_normalize_l3_addr(_canon_v6(addr6), iface)).ip))
            except Exception:
                pass

        if isinstance(ll6, str) and ll6 and not _conflicts_with_wan_peer(node, ifname, ll6):
            try:
                local6.add(str(ipaddress.ip_interface(_canon_v6(ll6)).ip))
            except Exception:
                pass

    return local4, local6


def _same_subnet(gateway: str | None, iface_addr: str | None) -> bool:
    if not gateway or not iface_addr:
        return False
    try:
        net = ipaddress.ip_interface(iface_addr).network
        gw = ipaddress.ip_address(gateway)
        return gw in net
    except Exception:
        return False


def _route_via_is_local(route: Dict[str, Any], family: int, local4: set[str], local6: set[str]) -> bool:
    if family == 4:
        via = _via4(route)
        return isinstance(via, str) and via in local4
    if family == 6:
        via = _via6(route)
        return isinstance(via, str) and via in local6
    return False


def _effective_via4(node: Dict[str, Any], iface: Dict[str, Any], route: Dict[str, Any]) -> str | None:
    via = _via4(route)
    local4, _ = _local_ips(node)

    if via in local4:
        via = None

    if not via and route.get("proto") == "uplink":
        via = _peer_in_subnet(iface.get("addr4"))

    if via in local4:
        via = _peer_in_subnet(iface.get("addr4"))

    if via in local4:
        return None

    if not _same_subnet(via, iface.get("addr4")):
        return None

    return via


def _effective_via6(node: Dict[str, Any], iface: Dict[str, Any], route: Dict[str, Any]) -> str | None:
    via = _via6(route)
    _, local6 = _local_ips(node)

    if via in local6:
        via = None

    if not via and route.get("proto") == "uplink":
        via = _peer_in_subnet(iface.get("addr6"))

    if via in local6:
        via = _peer_in_subnet(iface.get("addr6"))

    if via in local6:
        return None

    if not _same_subnet(via, iface.get("addr6")):
        return None

    return via


def _render_interfaces(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    interfaces = node.get("interfaces", {})

    for logical_if in sorted(interfaces.keys()):
        iface = interfaces[logical_if]
        if logical_if not in eth_map:
            continue

        eth = f"eth{eth_map[logical_if]}"

        if _is_virtual_interface(iface):
            cmds.append(
                f"sh -c 'ip link show {eth} >/dev/null 2>&1 || ip link add {eth} type dummy'"
            )

        cmds.append(f"ip link set {eth} up")

    return cmds


def _render_addressing(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")
        ll6 = iface.get("ll6")

        if isinstance(addr4, str) and addr4 and not _conflicts_with_wan_peer(node, ifname, addr4):
            addr4 = _normalize_l3_addr(addr4, iface)
            peer = _p2p_peer(addr4)
            if peer:
                ip = ipaddress.ip_interface(addr4).ip
                prefix = ipaddress.ip_interface(addr4).network.prefixlen
                cmds.append(
                    f"ip addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}"
                )
            else:
                cmds.append(f"ip addr replace {addr4} dev eth{eth}")

        if isinstance(addr6, str) and addr6 and not _conflicts_with_wan_peer(node, ifname, addr6):
            canon = _canon_v6(addr6)
            canon = _normalize_l3_addr(canon, iface)
            peer = _p2p_peer(canon)
            if peer:
                ip = ipaddress.ip_interface(canon).ip
                prefix = ipaddress.ip_interface(canon).network.prefixlen
                cmds.append(
                    f"ip -6 addr replace {ip}/{prefix} peer {peer}/{prefix} dev eth{eth}"
                )
            else:
                cmds.append(f"ip -6 addr replace {canon} dev eth{eth}")

        if isinstance(ll6, str) and ll6 and not _conflicts_with_wan_peer(node, ifname, ll6):
            cmds.append(f"ip -6 addr replace {_canon_v6(ll6)} dev eth{eth}")

    return cmds


def _render_static_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    connected4, connected6 = _connected_prefixes(node)
    local4, local6 = _local_ips(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for r in routes["ipv4"]:
            dst = _dst(r)
            via = _effective_via4(node, iface, r)

            if not dst or not via or dst == "0.0.0.0/0":
                continue

            dst = _normalize_prefix(dst)
            if r.get("proto") == "connected":
                continue
            if dst in connected4:
                continue
            if _route_via_is_local(r, 4, local4, local6):
                continue

            cmd = f"ip route replace {dst} via {via} dev eth{eth} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

        for r in routes["ipv6"]:
            dst = _dst(r)
            via = _effective_via6(node, iface, r)

            if not dst or not via or dst == "::/0":
                continue

            dst = _normalize_prefix(dst)
            if r.get("proto") == "connected":
                continue
            if dst in connected6:
                continue
            if _route_via_is_local(r, 6, local4, local6):
                continue

            cmd = f"ip -6 route replace {dst} via {via} dev eth{eth} onlink"
            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds


def _render_default_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()
    local4, local6 = _local_ips(node)

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for r in routes["ipv4"]:
            if _dst(r) != "0.0.0.0/0":
                continue
            if _route_via_is_local(r, 4, local4, local6):
                continue

            via = _effective_via4(node, iface, r)
            if via:
                cmd = f"ip route replace default via {via} dev eth{eth} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

        for r in routes["ipv6"]:
            if _dst(r) != "::/0":
                continue
            if _route_via_is_local(r, 6, local4, local6):
                continue

            via = _effective_via6(node, iface, r)
            if via:
                cmd = f"ip -6 route replace default via {via} dev eth{eth} onlink"
                if cmd not in seen:
                    seen.add(cmd)
                    cmds.append(cmd)

    return cmds


def _render_uplink_routes(node: Dict[str, Any], eth_map: Dict[str, int]) -> List[str]:
    cmds: List[str] = []
    seen: set[str] = set()

    for ifname in sorted((node.get("interfaces", {}) or {}).keys()):
        iface = node["interfaces"][ifname]
        eth = eth_map.get(ifname)
        if eth is None:
            continue

        routes = _route_lists(iface)

        for r in routes["ipv4"]:
            if r.get("proto") != "uplink":
                continue
            via = _effective_via4(node, iface, r)
            dst = _dst(r)
            if not via or not dst:
                continue

            if dst == "0.0.0.0/0":
                cmd = f"ip route replace default via {via} dev eth{eth} onlink"
            else:
                cmd = f"ip route replace {_normalize_prefix(dst)} via {via} dev eth{eth} onlink"

            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

        for r in routes["ipv6"]:
            if r.get("proto") != "uplink":
                continue
            via = _effective_via6(node, iface, r)
            dst = _dst(r)
            if not via or not dst:
                continue

            if dst == "::/0":
                cmd = f"ip -6 route replace default via {via} dev eth{eth} onlink"
            else:
                cmd = f"ip -6 route replace {_normalize_prefix(dst)} via {via} dev eth{eth} onlink"

            if cmd not in seen:
                seen.add(cmd)
                cmds.append(cmd)

    return cmds


def _is_bgp_router(role: str) -> bool:
    return role in _ROUTER_ROLES


def _first_router_id(node: Dict[str, Any]) -> str:
    candidates: List[str] = []

    for iface in (node.get("interfaces", {}) or {}).values():
        if not isinstance(iface, dict):
            continue

        addr4 = iface.get("addr4")
        if isinstance(addr4, str) and addr4:
            try:
                ipi = ipaddress.ip_interface(_normalize_l3_addr(addr4, iface))
                candidates.append(str(ipi.ip))
            except Exception:
                pass

    if not candidates:
        return "1.1.1.1"

    return sorted(candidates)[0]


def _network_statement_ipv4(addr: str, iface: Dict[str, Any]) -> str | None:
    try:
        normalized = _normalize_l3_addr(addr, iface)
        return str(ipaddress.ip_interface(normalized).network)
    except Exception:
        return None


def _network_statement_ipv6(addr: str, iface: Dict[str, Any]) -> str | None:
    try:
        normalized = _normalize_l3_addr(_canon_v6(addr), iface)
        return str(ipaddress.ip_interface(normalized).network)
    except Exception:
        return None


def _collect_bgp_networks(node: Dict[str, Any]) -> tuple[List[str], List[str]]:
    networks4: set[str] = set()
    networks6: set[str] = set()

    for ifname, iface in (node.get("interfaces", {}) or {}).items():
        if not isinstance(iface, dict):
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if isinstance(addr4, str) and addr4 and not _conflicts_with_wan_peer(node, ifname, addr4):
            net4 = _network_statement_ipv4(addr4, iface)
            if isinstance(net4, str):
                networks4.add(net4)

        if isinstance(addr6, str) and addr6 and not _conflicts_with_wan_peer(node, ifname, addr6):
            net6 = _network_statement_ipv6(addr6, iface)
            if isinstance(net6, str):
                networks6.add(net6)

    return sorted(networks4), sorted(networks6)


def _peer_ip(cidr: Any) -> str | None:
    if not isinstance(cidr, str) or not cidr:
        return None
    try:
        return str(ipaddress.ip_interface(cidr).ip)
    except Exception:
        return None


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

    ipv4_neighbors: List[tuple[str, int]] = []
    ipv6_neighbors: List[tuple[str, int]] = []

    for neighbor in neighbors:
        if not isinstance(neighbor, dict):
            continue

        peer_asn = neighbor.get("peer_asn")
        if not isinstance(peer_asn, int):
            continue

        peer_addr4 = _peer_ip(neighbor.get("peer_addr4"))
        peer_addr6 = _peer_ip(neighbor.get("peer_addr6"))

        if isinstance(peer_addr4, str):
            ipv4_neighbors.append((peer_addr4, peer_asn))
        if isinstance(peer_addr6, str):
            ipv6_neighbors.append((peer_addr6, peer_asn))

    ipv4_neighbors = sorted(set(ipv4_neighbors), key=lambda item: item[0])
    ipv6_neighbors = sorted(set(ipv6_neighbors), key=lambda item: item[0])

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

    for peer_ip, peer_asn in ipv4_neighbors:
        config_lines.append(f" neighbor {peer_ip} remote-as {peer_asn}")

    for peer_ip, peer_asn in ipv6_neighbors:
        config_lines.append(f" neighbor {peer_ip} remote-as {peer_asn}")

    config_lines.append(" !")
    config_lines.append(" address-family ipv4 unicast")
    config_lines.append("  redistribute connected")
    config_lines.append("  redistribute static")
    for network in networks4:
        config_lines.append(f"  network {network}")
    for peer_ip, _peer_asn in ipv4_neighbors:
        config_lines.append(f"  neighbor {peer_ip} activate")
    config_lines.append(" exit-address-family")
    config_lines.append(" !")
    config_lines.append(" address-family ipv6 unicast")
    config_lines.append("  redistribute connected")
    config_lines.append("  redistribute static")
    for network in networks6:
        config_lines.append(f"  network {network}")
    for peer_ip, _peer_asn in ipv6_neighbors:
        config_lines.append(f"  neighbor {peer_ip} activate")
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

    python_script = (
        "import json, pathlib\n"
        f"payload = json.loads({json.dumps(json.dumps(payload))})\n"
        "pathlib.Path('/etc/frr').mkdir(parents=True, exist_ok=True)\n"
        "daemon_lines = [f\"{k}={v}\" for k, v in payload['daemons'].items()]\n"
        "pathlib.Path('/etc/frr/daemons').write_text('\\n'.join(daemon_lines) + '\\n')\n"
        "pathlib.Path('/etc/frr/frr.conf').write_text(payload['frr_conf'])\n"
        "pathlib.Path('/etc/frr/vtysh.conf').write_text(payload['vtysh_conf'])\n"
    )

    return [
        "mkdir -p /var/run/frr /etc/frr",
        "touch /etc/frr/daemons /etc/frr/frr.conf /etc/frr/vtysh.conf",
        f"python3 -c {json.dumps(python_script)}",
        "chown -R frr:frr /etc/frr /var/run/frr >/dev/null 2>&1 || true",
        "chmod 640 /etc/frr/daemons /etc/frr/frr.conf /etc/frr/vtysh.conf >/dev/null 2>&1 || true",
        "pkill -x zebra >/dev/null 2>&1 || true",
        "pkill -x bgpd >/dev/null 2>&1 || true",
        "/usr/lib/frr/frrinit.sh restart >/dev/null 2>&1 || /etc/init.d/frr restart >/dev/null 2>&1 || service frr restart >/dev/null 2>&1 || true",
        "sleep 1",
        "vtysh -c 'show bgp ipv4 summary' >/dev/null 2>&1 || true",
        "vtysh -c 'show bgp ipv6 summary' >/dev/null 2>&1 || true",
    ]


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, int],
) -> List[str]:
    cmds: List[str] = [
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
    ]

    routing_mode = str(node_data.get("routing_mode", "static")).strip().lower()
    if routing_mode not in {"static", "bgp"}:
        routing_mode = "static"

    cmds.extend(_render_interfaces(node_data, eth_map))
    cmds.extend(_render_addressing(node_data, eth_map))

    if routing_mode == "bgp" and _is_bgp_router(role):
        cmds.extend(_render_uplink_routes(node_data, eth_map))
        cmds.extend(_render_bgp(node_name, node_data, role))
    elif role != "wan-peer":
        cmds.extend(_render_static_routes(node_data, eth_map))
        cmds.extend(_render_default_routes(node_data, eth_map))

    cmds.extend(render_cm(role, node_data.get("_cm_inputs", {})))

    return cmds
