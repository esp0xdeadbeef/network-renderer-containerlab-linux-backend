from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh


def _rows(node_data: Dict[str, Any]) -> List[Dict[str, Any]]:
    upstream = node_data.get("upstreamEmulation")
    if not isinstance(upstream, dict):
        return []
    rows: List[Dict[str, Any]] = []
    for row in upstream.values():
        if isinstance(row, dict) and row.get("mode") == "pppoe":
            rows.append(row)
    return rows


def _client_interface(row: Dict[str, Any], node_data: Dict[str, Any], eth_map: Dict[str, str]) -> str | None:
    client = row.get("pppoe", {}).get("client", {})
    if not isinstance(client, dict):
        return None
    logical_if = client.get("coreInterface")
    if not isinstance(logical_if, str) or not logical_if:
        return None
    interfaces = node_data.get("interfaces", {})
    if not isinstance(interfaces, dict) or logical_if not in interfaces:
        return None
    return eth_map.get(logical_if)


def _client_commands(row: Dict[str, Any], node_data: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    client = row.get("pppoe", {}).get("client", {})
    if not isinstance(client, dict) or client.get("coreNode") != node_data.get("name"):
        return []
    iface = _client_interface(row, node_data, eth_map)
    if iface is None:
        raise ValueError(
            f"PPPoE client {node_data.get('name')!r} missing explicit rendered interface for {client.get('coreInterface')!r}"
        )
    runtime_iface = str(client.get("runtimeInterface") or "ppp0")
    mtu = int(client.get("mtu") or row.get("handoff", {}).get("mtu") or 1492)
    server = row.get("pppoe", {}).get("server", {})
    credentials = server.get("credentials", {}) if isinstance(server, dict) else {}
    username_file = str(credentials.get("usernameFile") or "/run/secrets/pppoe-username")
    password_file = str(credentials.get("passwordFile") or "/run/secrets/pppoe-password")
    return [
        _sh(f"ip link set {iface} up"),
        _sh("mkdir -p /run/ppp"),
        _sh(
            "sh -c '"
            f"user=$(cat {username_file} 2>/dev/null || printf s88-lab); "
            f"pass=$(cat {password_file} 2>/dev/null || printf s88-lab); "
            "printf \"%s * %s *\\n\" \"$user\" \"$pass\" >/etc/ppp/chap-secrets; "
            "printf \"%s * %s *\\n\" \"$user\" \"$pass\" >/etc/ppp/pap-secrets'"
        ),
        _sh(
            "nohup pppd "
            f"pty 'pppoe -I {iface}' user s88-lab noauth noipdefault "
            "defaultroute replacedefaultroute usepeerdns persist maxfail 0 "
            f"mtu {mtu} mru {mtu} ipparam {runtime_iface} "
            f">/tmp/s88-pppoe-client-{iface}.log 2>&1 &"
        ),
    ]


def _server_commands(row: Dict[str, Any], node_name: str) -> List[str]:
    pppoe = row.get("pppoe", {})
    server = pppoe.get("server") if isinstance(pppoe, dict) else {}
    if not isinstance(server, dict) or server.get("node") != node_name:
        return []
    session = server.get("session", {})
    if not isinstance(session, dict):
        session = {}
    provider = str(session.get("providerAddress") or "203.0.113.1")
    customer = str(session.get("customerAddress") or "203.0.113.2")
    return [
        _sh("ip link set eth1 up"),
        _sh(
            "nohup pppoe-server "
            f"-I eth1 -L {provider} -R {customer} -N 32 "
            f">/tmp/s88-pppoe-server-{node_name}.log 2>&1 &"
        ),
    ]


def render(node_name: str, node_data: Dict[str, Any], eth_map: Dict[str, str]) -> List[str]:
    cmds: List[str] = []
    for row in _rows(node_data):
        cmds.extend(_client_commands(row, node_data, eth_map))
        cmds.extend(_server_commands(row, node_name))
    return cmds
