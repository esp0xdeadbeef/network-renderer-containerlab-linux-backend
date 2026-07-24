# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-020
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


def _bool_option(
    config: Dict[str, Any], field: str, default: bool | None = None
) -> bool:
    value = config.get(field)
    if value is None:
        if default is not None:
            return default
        raise ValueError(
            f"CLAB PPPoE service requires {field} — CPM must provide explicit True/False"
        )
    return value is not False


def _ipv6_prefix_delegation(config: Dict[str, Any]) -> Dict[str, Any] | None:
    value = config.get("ipv6")
    if value is None:
        return None
    allowed_fields = {
        "mode",
        "defaultRoute",
        "iaid",
        "prefixDelegationRequestId",
        "duidMode",
        "resolverMode",
        "ipv4Mode",
        "routerSolicitation",
        "fallbackPolicy",
    }
    if not isinstance(value, dict) or set(value) != allowed_fields:
        raise ValueError(
            "CLAB PPPoE IPv6/PD requires the complete explicit CPM contract"
        )
    if (
        value.get("mode") != "dhcpv6-pd"
        or not isinstance(value.get("defaultRoute"), bool)
        or not isinstance(value.get("iaid"), int)
        or isinstance(value.get("iaid"), bool)
        or value["iaid"] <= 0
        or not isinstance(value.get("prefixDelegationRequestId"), int)
        or isinstance(value.get("prefixDelegationRequestId"), bool)
        or value["prefixDelegationRequestId"] <= 0
        or value.get("duidMode") != "persistent"
        or value.get("resolverMode") != "disabled"
        or value.get("ipv4Mode") != "disabled"
        or value.get("routerSolicitation") is not False
        or value.get("fallbackPolicy") != "none"
    ):
        raise ValueError(
            "CLAB PPPoE IPv6/PD rejected incomplete or fallback-enabled CPM input"
        )
    return value


def _client_command(config: Dict[str, Any], eth_map: Dict[str, str]) -> str:
    ifname = _interface(config, eth_map, "client")
    credentials = _dict(config.get("credentials"))
    ppp_name = config.get("runtimeInterface")
    if not isinstance(ppp_name, str) or not ppp_name:
        raise ValueError(
            "CLAB PPPoE client runtimeInterface must come from CPM "
            "services.pppoe.client.runtimeInterface"
        )
    mtu_raw = config.get("mtu")
    if mtu_raw is None:
        raise ValueError(
            "CLAB PPPoE client requires mtu from CPM services.pppoe.client.mtu"
        )
    mtu = str(mtu_raw)
    default_route = (
        "defaultroute replacedefaultroute"
        if _bool_option(config, "defaultRoute")
        else "nodefaultroute"
    )
    use_peer_dns = "usepeerdns" if _bool_option(config, "usePeerDns") else ""
    ipv6 = _ipv6_prefix_delegation(config)
    default_route6 = "defaultroute6" if ipv6 and ipv6["defaultRoute"] else ""
    commands = [
        "command -v pppd >/dev/null || { echo 'missing pppd' >&2; exit 1; }",
        "command -v pppoe >/dev/null || { echo 'missing pppoe' >&2; exit 1; }",
        "mkdir -p /etc/ppp /run/ppp /run/pppd",
        f"ip link set {shlex.quote(ifname)} up",
        f'user="$({_credential_command(credentials, "username")})"',
        f'pass="$({_credential_command(credentials, "password")})"',
        "install -m 0600 /dev/null /etc/ppp/chap-secrets",
        "install -m 0600 /dev/null /etc/ppp/pap-secrets",
        'printf \'%s * %s *\\n\' "$user" "$pass" > /etc/ppp/chap-secrets',
        'printf \'%s * %s *\\n\' "$user" "$pass" > /etc/ppp/pap-secrets',
        "pkill -x pppd >/dev/null 2>&1 || true",
        (
            "nohup pppd "
            f"pty {shlex.quote('pppoe -I ' + ifname)} "
            f"ifname {shlex.quote(ppp_name)} "
            'user "$user" password "$pass" '
            "noauth noipdefault "
            f"{default_route} {default_route6} {use_peer_dns} "
            "persist maxfail 0 +ipv6 ipv6cp-accept-local ipv6cp-accept-remote "
            f"mtu {shlex.quote(mtu)} mru {shlex.quote(mtu)} "
            f">/tmp/s88-pppoe-client-{shlex.quote(ifname)}.log 2>&1 &"
        ),
    ]
    if ipv6 is not None:
        supervisor = "\n".join(
            [
                "while :; do",
                f"  while ! ip link show dev {shlex.quote(ppp_name)} >/dev/null 2>&1; do sleep 2; done",
                (
                    "  if ! dhcpcd -6 -d -B -f /etc/s88-pppoe-ipv6-pd.conf "
                    f"{shlex.quote(ppp_name)}; then"
                ),
                "    echo 'PPPoE DHCPv6-PD client exited; retrying' >&2",
                "  fi",
                "  sleep 2",
                "done",
            ]
        )
        commands.extend(
            [
                "command -v dhcpcd >/dev/null || { echo 'missing dhcpcd' >&2; exit 1; }",
                "cat >/etc/s88-pppoe-ipv6-pd.conf <<'EOF'",
                "duid",
                "persistent",
                "nohook resolv.conf",
                "noipv6rs",
                "noipv4",
                "ipv6only",
                "",
                f"interface {ppp_name}",
                f"  iaid {ipv6['iaid']}",
                f"  ia_pd {ipv6['prefixDelegationRequestId']}",
                "EOF",
                (
                    "nft add rule inet filter input "
                    f"iifname {shlex.quote(ppp_name)} ip6 saddr fe80::/10 "
                    "udp sport 547 udp dport 546 counter accept "
                    'comment "s88-pppoe-dhcpv6-pd-replies"'
                ),
                (
                    f"nohup sh -c {shlex.quote(supervisor)} "
                    ">/tmp/s88-pppoe-ipv6-pd.log 2>&1 &"
                ),
            ]
        )
    return "\n".join(commands)


def _server_command(config: Dict[str, Any], eth_map: Dict[str, str]) -> str:
    ifname = _interface(config, eth_map, "server")
    credentials = _dict(config.get("credentials"))
    provider_address = _string(
        config.get("providerAddress"), "services.pppoe.server.providerAddress"
    )
    customer_address = _string(
        config.get("customerAddress"), "services.pppoe.server.customerAddress"
    )
    mtu_raw = config.get("mtu")
    if mtu_raw is None:
        raise ValueError(
            "CLAB PPPoE server requires mtu from CPM services.pppoe.server.mtu"
        )
    mtu = str(mtu_raw)
    max_sessions_raw = config.get("maxSessions")
    if max_sessions_raw is None:
        raise ValueError(
            "CLAB PPPoE server requires maxSessions from CPM services.pppoe.server.maxSessions"
        )
    max_sessions = str(max_sessions_raw)
    return "\n".join(
        [
            "command -v pppoe-server >/dev/null || { echo 'missing pppoe-server' >&2; exit 1; }",
            "command -v pppd >/dev/null || { echo 'missing pppd' >&2; exit 1; }",
            "mkdir -p /etc/ppp /run/ppp",
            f"ip link set {shlex.quote(ifname)} up",
            f'user="$({_credential_command(credentials, "username")})"',
            f'pass="$({_credential_command(credentials, "password")})"',
            "install -m 0600 /dev/null /etc/ppp/chap-secrets",
            "install -m 0600 /dev/null /etc/ppp/pap-secrets",
            'printf \'%s * %s *\\n\' "$user" "$pass" > /etc/ppp/chap-secrets',
            "printf '* * %s *\\n' \"$pass\" >> /etc/ppp/chap-secrets",
            'printf \'%s * %s *\\n\' "$user" "$pass" > /etc/ppp/pap-secrets',
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
            "pkill -x pppoe-server >/dev/null 2>&1 || true",
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
