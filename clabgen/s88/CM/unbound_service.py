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


def _safe_stem(value: str) -> str:
    return value.replace("/", "-").replace(":", "-").replace(" ", "-")


def _protected_reservation_artifacts(
    dns: Dict[str, Any],
) -> tuple[List[str], List[str]]:
    raw = dns.get("protectedReservationPublications", [])
    if not isinstance(raw, list):
        _fail("CPM emitted a malformed protected reservation publication list")
    includes: List[str] = []
    namespaces: List[str] = []
    for publication in raw:
        if not isinstance(publication, dict):
            _fail("CPM emitted a malformed protected reservation publication")
        allowed_fields = {
            "source",
            "scopeId",
            "namespace",
            "ownerScope",
            "requesterScopes",
            "recordClasses",
            "materializerFamily",
            "fallbackBehavior",
            "publicationDenialDiagnostic",
        }
        if set(publication) - allowed_fields:
            _fail("CPM leaked unsupported protected reservation publication fields")
        source = publication.get("source")
        scope_id = publication.get("scopeId")
        owner_scope = publication.get("ownerScope")
        requester_scopes = publication.get("requesterScopes")
        record_classes = publication.get("recordClasses")
        if (
            not isinstance(source, dict)
            or source.get("schema") != "gamp-protected-reservation-set-v1"
            or source.get("sourceClass") != "protected"
            or not isinstance(source.get("sourceFile"), str)
            or not source["sourceFile"].startswith("/run/secrets/")
            or source["sourceFile"] == "/run/secrets/"
            or "/../" in source["sourceFile"]
        ):
            _fail("CPM emitted an unapproved protected reservation source")
        if (
            not isinstance(scope_id, str)
            or not scope_id
            or owner_scope != scope_id
            or not isinstance(requester_scopes, list)
            or not requester_scopes
            or not all(isinstance(item, str) and item for item in requester_scopes)
            or owner_scope not in requester_scopes
            or "*" in requester_scopes
            or not isinstance(publication.get("namespace"), str)
            or not re.fullmatch(_ZONE_NAME_PATTERN, publication["namespace"])
        ):
            _fail("CPM emitted an unscoped protected reservation publication")
        if (
            not isinstance(record_classes, list)
            or not record_classes
            or len(record_classes) != len(set(record_classes))
            or not set(record_classes).issubset({"A", "AAAA", "PTR"})
        ):
            _fail("CPM emitted invalid protected reservation record classes")
        if (
            publication.get("materializerFamily") not in {"ipv4", "ipv6"}
            or publication.get("fallbackBehavior") != "local-only"
            or not isinstance(publication.get("publicationDenialDiagnostic"), str)
            or not publication["publicationDenialDiagnostic"]
        ):
            _fail("CPM emitted a non-reproducible protected reservation policy")
        include_path = f"/run/protected-reservation-dns/{_safe_stem(scope_id)}.conf"
        if include_path in includes:
            _fail("CPM emitted duplicate protected reservation publication owners")
        namespace = publication["namespace"]
        if namespace in namespaces:
            _fail("CPM emitted duplicate protected reservation namespace owners")
        includes.append(include_path)
        namespaces.append(namespace)
    return includes, namespaces


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
    protected_reservation_includes, protected_reservation_namespaces = (
        _protected_reservation_artifacts(dns)
    )

    local_zones: List[tuple[str, str]] = []
    for zone in _dict_list(dns.get("localZones", [])):
        local_zones.append((_zone_name(zone.get("name")), _zone_type(zone.get("type"))))
    for namespace in protected_reservation_namespaces:
        if any(name == namespace and zone_type != "static" for name, zone_type in local_zones):
            _fail("CPM emitted a conflicting protected reservation namespace authority")
        local_zones.append((namespace, "static"))
    namespace_fallback = dns.get("namespaceFallback")
    if isinstance(namespace_fallback, dict):
        for decision in _dict_list(namespace_fallback.get("decisions", [])):
            if decision.get("action") in {"block", "deny"} and not decision.get(
                "publicRecursionFallback", False
            ):
                local_zones.append((_zone_name(decision.get("namespace")), "static"))
    if authority["recursionMode"] == "local-only":
        local_zones.append((".", "refuse"))
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
    if any(name in protected_reservation_namespaces for name, _, _ in forward_zones):
        _fail("CPM forwarded a protected reservation namespace outside its local authority")

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
        *[f"include: {_quote(path)}" for path in protected_reservation_includes],
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
