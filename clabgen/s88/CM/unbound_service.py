from __future__ import annotations

from ipaddress import ip_address, ip_network
import re
import shlex
from typing import Any, Dict, List


_ZONE_NAME_PATTERN = r"^(?:\.|[A-Za-z0-9_.-]+\.)$"
_ZONE_TYPES = {"static", "transparent", "refuse", "deny", "always_refuse"}
_WARNING_CODE_PATTERN = r"^[A-Z0-9_,]+$"


def _sh(script: str) -> str:
    return "sh -c " + shlex.quote(script)


def _fail(reason: str) -> None:
    raise ValueError(
        "CLAB DNS DNS_RENDERER_CONTRACT_DIVERGENCE: "
        + reason
        + "; address material is intentionally omitted"
    )


def _string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item]


def _dict_list(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _address(value: str) -> str:
    try:
        return str(ip_address(value))
    except ValueError:
        _fail("CPM emitted a malformed DNS address")


def _prefix(value: str) -> str:
    try:
        return str(ip_network(value, strict=False))
    except ValueError:
        _fail("CPM emitted a malformed DNS requester prefix")


def _zone_name(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(_ZONE_NAME_PATTERN, value):
        _fail("CPM emitted a malformed DNS namespace")
    return value


def _zone_type(value: Any) -> str:
    rendered = value if isinstance(value, str) else "static"
    if rendered not in _ZONE_TYPES:
        _fail("CPM emitted an unsupported local-zone action")
    return rendered


def _unique(values: List[str]) -> List[str]:
    result: List[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def render_unbound_dns_service(
    dns: Dict[str, Any],
    authority: Dict[str, Any],
    pre_start_commands: List[str] | None = None,
) -> List[str]:
    listen = _unique(
        ["127.0.0.1", "::1"]
        + [_address(value) for value in _string_list(dns.get("listen", []))]
    )
    if len(listen) == 2:
        return []

    allow_from = _unique(
        ["127.0.0.0/8", "::1/128"]
        + [_prefix(value) for value in _string_list(dns.get("allowFrom", []))]
    )
    requester_actions: List[tuple[str, str]] = []
    for policy in authority["requesterPolicies"]:
        action = policy.get("action")
        if action != "refuse_non_local":
            _fail("CPM emitted an unsupported requester action")
        for value in _string_list(policy.get("sourcePrefixes", [])):
            requester_actions.append((_prefix(value), action))

    outgoing_interfaces = _unique(
        [_address(value) for value in _string_list(dns.get("outgoingInterfaces", []))]
    )

    local_zones: List[tuple[str, str]] = []
    for zone in _dict_list(dns.get("localZones", [])):
        local_zones.append((_zone_name(zone.get("name")), _zone_type(zone.get("type"))))
    namespace_fallback = dns.get("namespaceFallback")
    if isinstance(namespace_fallback, dict):
        for decision in _dict_list(namespace_fallback.get("decisions", [])):
            if decision.get("action") in {"block", "deny"} and not decision.get(
                "publicRecursionFallback", False
            ):
                local_zones.append((_zone_name(decision.get("namespace")), "static"))
    if authority["recursionMode"] == "local-only":
        local_zones.append((".", "static"))
    local_zones = list(dict.fromkeys(local_zones))

    local_data: List[str] = []
    for record in _dict_list(dns.get("localRecords", [])):
        name = _zone_name(record.get("name"))
        for value in _string_list(record.get("a", [])):
            local_data.append(f"{name} IN A {_address(value)}")
        for value in _string_list(record.get("aaaa", [])):
            local_data.append(f"{name} IN AAAA {_address(value)}")

    forward_zones: List[tuple[str, List[str], bool]] = []
    root_forwarders = [_address(value) for value in authority["rootForwarders"]]
    if root_forwarders:
        forward_zones.append((".", root_forwarders, False))
    for zone in authority["localForwardZones"]:
        forward_zones.append(
            (
                _zone_name(zone.get("name")),
                [_address(value) for value in _string_list(zone.get("forwardTo", []))],
                bool(zone.get("forwardFirst", False)),
            )
        )

    warning_commands: List[str] = []
    for code in authority["warningCodes"]:
        if not re.fullmatch(_WARNING_CODE_PATTERN, code):
            _fail("CPM emitted a malformed DNS warning code")
        warning_commands.append(
            "printf '%s\\n' "
            + shlex.quote(
                f"CLAB DNS reproducibility warning {code}; address material is intentionally omitted"
            )
            + " >&2"
        )

    config = [
        "server:",
        '  username: "unbound"',
        '  chroot: ""',
        '  directory: "/tmp"',
        '  pidfile: "/tmp/clabgen-unbound.pid"',
        "  do-ip4: yes",
        "  do-ip6: yes",
        "  hide-identity: yes",
        "  hide-version: yes",
        "  log-queries: no",
        "  log-replies: no",
    ]
    for value in listen:
        config.append(f"  interface: {_quote(value)}")
    for value in allow_from:
        config.append(f"  access-control: {_quote(value)} allow")
    for prefix, action in requester_actions:
        config.append(f"  access-control: {_quote(prefix)} {action}")
    for value in outgoing_interfaces:
        config.append(f"  outgoing-interface: {_quote(value)}")
    for name, zone_type in local_zones:
        config.append(f"  local-zone: {_quote(name)} {zone_type}")
    for record in local_data:
        config.append(f"  local-data: {_quote(record)}")
    validation_authority = authority.get("validationAuthority")
    if authority["recursionMode"] == "iterative":
        if isinstance(validation_authority, dict):
            config.extend(
                [
                    '  root-hints: "/tmp/clabgen-controlled-root.hints"',
                    '  domain-insecure: "."',
                ]
            )
        else:
            config.append('  auto-trust-anchor-file: "/tmp/clabgen-unbound-root.key"')
    for name, forwarders, forward_first in forward_zones:
        config.extend(["forward-zone:", f"  name: {_quote(name)}"])
        for value in forwarders:
            config.append(f"  forward-addr: {_quote(value)}")
        config.append(f"  forward-first: {'yes' if forward_first else 'no'}")

    script_lines = list(pre_start_commands or []) + warning_commands
    if authority["recursionMode"] == "iterative":
        if isinstance(validation_authority, dict):
            root = validation_authority["root"]
            root_hints = [
                f". 60 IN NS {root['nameServer']}",
                *[f"{root['nameServer']} 60 IN A {value}" for value in root["ipv4"]],
                *[f"{root['nameServer']} 60 IN AAAA {value}" for value in root["ipv6"]],
            ]
            script_lines.extend(
                [
                    "cat >/tmp/clabgen-controlled-root.hints <<'CONTROLLED_ROOT_HINTS'",
                    *root_hints,
                    "CONTROLLED_ROOT_HINTS",
                ]
            )
        else:
            script_lines.append(
                "install -o unbound -g unbound -m 0600 /usr/share/dns/root.key /tmp/clabgen-unbound-root.key"
            )

    non_loopback_listen = [
        value for value in listen if value not in {"127.0.0.1", "::1"}
    ]
    address_ready = " && ".join(
        "ip -o address show | "
        + f"awk -v address={shlex.quote(value)} "
        + '\'($4 == address || index($4, address "/") == 1) && '
        + "$0 !~ / (tentative|dadfailed)( |$)/ { found=1 } "
        + "END { exit !found }'"
        for value in non_loopback_listen
    )
    socket_ready = " && ".join(
        "ss -H -lnut 'sport = :53' | " + f"grep -F -- {shlex.quote(value)} >/dev/null"
        for value in non_loopback_listen
    )
    reconcile_lines = [
        "#!/bin/sh",
        "set -eu",
        'if [ -s /tmp/clabgen-unbound.pid ]; then kill "$(cat /tmp/clabgen-unbound.pid)" >/dev/null 2>&1 || true; fi',
        "rm -f /tmp/clabgen-unbound.pid",
        "dns_listener_ready=0",
        "for attempt in $(seq 1 3000); do",
        f"  if {address_ready}; then dns_listener_ready=1; break; fi",
        "  sleep 0.1",
        "done",
        "[ \"$dns_listener_ready\" -eq 1 ] || { printf '%s\\n' 'DNS listener endpoints did not become available; address material is intentionally omitted' >&2; exit 1; }",
        "nohup unbound -d -c /tmp/clabgen-unbound.conf >/tmp/clabgen-unbound.log 2>&1 &",
        "unbound_pid=$!",
        "dns_resolver_ready=0",
        "for attempt in $(seq 1 600); do",
        '  kill -0 "$unbound_pid" 2>/dev/null || break',
        f"  if {socket_ready}; then dns_resolver_ready=1; break; fi",
        "  sleep 0.1",
        "done",
        "[ \"$dns_resolver_ready\" -eq 1 ] || { kill \"$unbound_pid\" 2>/dev/null || true; printf '%s\\n' 'DNS resolver did not remain available; address material is intentionally omitted' >&2; exit 1; }",
    ]
    script_lines.extend(
        [
            "cat >/tmp/clabgen-unbound.conf <<'UNBOUND'",
            *config,
            "UNBOUND",
            "unbound-checkconf /tmp/clabgen-unbound.conf >/dev/null",
            "cat >/tmp/clabgen-reconcile-unbound.sh <<'RECONCILE_UNBOUND'",
            *reconcile_lines,
            "RECONCILE_UNBOUND",
            "chmod 0700 /tmp/clabgen-reconcile-unbound.sh",
        ]
    )
    return [_sh("\n".join(script_lines) + "\n")]
