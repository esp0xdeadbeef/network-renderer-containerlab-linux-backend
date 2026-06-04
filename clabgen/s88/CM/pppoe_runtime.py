from __future__ import annotations

import shlex
from typing import Any, Dict, List

from clabgen.s88.CM.linux_shell import _sh


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"CLAB PPPoE service requires {field}")
    return value


def _interface(config: Dict[str, Any], eth_map: Dict[str, str], side: str) -> str:
    logical = _string(config.get("interface"), f"services.pppoe.{side}.interface")
    runtime = eth_map.get(logical)
    if not isinstance(runtime, str) or not runtime:
        raise ValueError(
            f"CLAB PPPoE {side} interface {logical!r} has no rendered runtime interface"
        )
    return runtime


def _credential_command(credentials: Dict[str, Any], field: str) -> str:
    file_field = f"{field}File"
    file_value = credentials.get(file_field)
    value = credentials.get(field)
    if isinstance(file_value, str) and file_value:
        return f"cat {shlex.quote(file_value)}"
    if isinstance(value, str):
        return f"printf %s {shlex.quote(value)}"
    raise ValueError(f"CLAB PPPoE service requires credentials.{field}")


def _bool_option(config: Dict[str, Any], field: str, default: bool) -> bool:
    value = config.get(field)
    if value is None:
        return default
    return value is not False


def _client_command(config: Dict[str, Any], eth_map: Dict[str, str]) -> str:
    ifname = _interface(config, eth_map, "client")
    credentials = _dict(config.get("credentials"))
    ppp_name = config.get("runtimeInterface") or "ppp0"
    if not isinstance(ppp_name, str) or not ppp_name:
        raise ValueError("CLAB PPPoE client runtimeInterface must be a string")
    mtu = str(config.get("mtu") or 1492)
    default_route = (
        "defaultroute replacedefaultroute"
        if _bool_option(config, "defaultRoute", True)
        else "nodefaultroute"
    )
    use_peer_dns = "usepeerdns" if _bool_option(config, "usePeerDns", True) else ""
    return "\n".join(
        [
            "command -v pppd >/dev/null || { echo 'missing pppd' >&2; exit 1; }",
            "command -v pppoe >/dev/null || { echo 'missing pppoe' >&2; exit 1; }",
            "mkdir -p /etc/ppp /run/pppd",
            f"ip link set {shlex.quote(ifname)} up",
            f"user=\"$({_credential_command(credentials, 'username')})\"",
            f"pass=\"$({_credential_command(credentials, 'password')})\"",
            "install -m 0600 /dev/null /etc/ppp/chap-secrets",
            "install -m 0600 /dev/null /etc/ppp/pap-secrets",
            "printf '%s * %s *\\n' \"$user\" \"$pass\" > /etc/ppp/chap-secrets",
            "printf '%s * %s *\\n' \"$user\" \"$pass\" > /etc/ppp/pap-secrets",
            f"pkill -f 'pppoe -I {shlex.quote(ifname)}' >/dev/null 2>&1 || true",
            (
                "nohup pppd "
                f"pty {shlex.quote('pppoe -I ' + ifname)} "
                f"ifname {shlex.quote(ppp_name)} "
                'user "$user" password "$pass" '
                "noauth noipdefault "
                f"{default_route} {use_peer_dns} "
                "persist maxfail 0 +ipv6 ipv6cp-accept-local ipv6cp-accept-remote "
                f"mtu {shlex.quote(mtu)} mru {shlex.quote(mtu)} "
                f">/tmp/s88-pppoe-client-{shlex.quote(ifname)}.log 2>&1 &"
            ),
        ]
    )


def _server_command(config: Dict[str, Any], eth_map: Dict[str, str]) -> str:
    ifname = _interface(config, eth_map, "server")
    credentials = _dict(config.get("credentials"))
    provider_address = _string(
        config.get("providerAddress"), "services.pppoe.server.providerAddress"
    )
    customer_address = _string(
        config.get("customerAddress"), "services.pppoe.server.customerAddress"
    )
    mtu = str(config.get("mtu") or 1492)
    max_sessions = str(config.get("maxSessions") or 32)
    return "\n".join(
        [
            "command -v pppoe-server >/dev/null || { echo 'missing pppoe-server' >&2; exit 1; }",
            "command -v pppd >/dev/null || { echo 'missing pppd' >&2; exit 1; }",
            "mkdir -p /etc/ppp",
            f"ip link set {shlex.quote(ifname)} up",
            f"user=\"$({_credential_command(credentials, 'username')})\"",
            f"pass=\"$({_credential_command(credentials, 'password')})\"",
            "install -m 0600 /dev/null /etc/ppp/chap-secrets",
            "install -m 0600 /dev/null /etc/ppp/pap-secrets",
            "printf '%s * %s *\\n' \"$user\" \"$pass\" > /etc/ppp/chap-secrets",
            "printf '* * %s *\\n' \"$pass\" >> /etc/ppp/chap-secrets",
            "printf '%s * %s *\\n' \"$user\" \"$pass\" > /etc/ppp/pap-secrets",
            "printf '* * %s *\\n' \"$pass\" >> /etc/ppp/pap-secrets",
            "cat >/etc/ppp/s88-pppoe-server-options <<'EOF'",
            "require-pap",
            "refuse-chap",
            "refuse-mschap",
            "refuse-mschap-v2",
            "refuse-eap",
            "noauth",
            "nobsdcomp",
            "nodeflate",
            "noccp",
            "novj",
            "+ipv6",
            "ipv6cp-accept-local",
            "ipv6cp-accept-remote",
            "lcp-echo-interval 10",
            "lcp-echo-failure 3",
            f"mtu {mtu}",
            f"mru {mtu}",
            f"ms-dns {provider_address}",
            "EOF",
            f"pkill -f 'pppoe-server -I {shlex.quote(ifname)}' >/dev/null 2>&1 || true",
            (
                "nohup pppoe-server "
                f"-I {shlex.quote(ifname)} "
                f"-L {shlex.quote(provider_address)} "
                f"-R {shlex.quote(customer_address)} "
                "-O /etc/ppp/s88-pppoe-server-options "
                "-q /usr/sbin/pppd "
                "-Q /usr/sbin/pppoe "
                f"-N {shlex.quote(max_sessions)} "
                f">/tmp/s88-pppoe-server-{shlex.quote(ifname)}.log 2>&1 &"
            ),
        ]
    )


def render(
    node_name: str, node_data: Dict[str, Any], eth_map: Dict[str, str]
) -> List[str]:
    del node_name
    services = _dict(node_data.get("services"))
    pppoe = _dict(services.get("pppoe"))
    if not pppoe:
        return []

    cmds: List[str] = []
    client = pppoe.get("client")
    server = pppoe.get("server")
    if isinstance(client, dict):
        cmds.append(_sh(_client_command(client, eth_map)))
    if isinstance(server, dict):
        cmds.append(_sh(_server_command(server, eth_map)))
    return cmds
