from __future__ import annotations

from ipaddress import ip_address, ip_interface, ip_network
from pathlib import Path
from typing import Any, Dict, List
import json
import shlex

from clabgen.s88.CM.dns_authority import (
    normalize_dns_authority,
    normalize_dns_egress_policy,
)
from clabgen.s88.CM.unbound_service import render_unbound_dns_service


RUNTIME_SCRIPT = Path(__file__).with_name("dns_proxy_runtime.py")
PROTOCOL_SCRIPT = Path(__file__).with_name("dns_proxy_protocol.py")


def _sh(script: str) -> str:
    return "sh -c " + shlex.quote(script)


def _nft_literal(value: str) -> str:
    return shlex.quote(value)


def _dns_renderer_fail(reason: str) -> None:
    raise ValueError(
        "CLAB DNS DNS_RENDERER_CONTRACT_DIVERGENCE: "
        + reason
        + "; address material is intentionally omitted"
    )


def _dns_validation_fail(reason: str) -> None:
    raise ValueError(
        "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: "
        + reason
        + "; address material is intentionally omitted"
    )


def _service_endpoint_address_commands(
    node: Dict[str, Any], dns: Dict[str, Any]
) -> List[str]:
    bindings = dns.get("serviceEndpointBindings", [])
    if not isinstance(bindings, list) or not bindings:
        return []

    interfaces = node.get("interfaces", {})
    if not isinstance(interfaces, dict):
        _dns_renderer_fail("service endpoint binding has no explicit interface set")

    commands: List[str] = []
    for binding in bindings:
        if not isinstance(binding, dict):
            _dns_renderer_fail("service endpoint binding is malformed")
        terminal_attachment = binding.get("terminalAttachmentId")
        if not isinstance(terminal_attachment, str) or not terminal_attachment:
            _dns_renderer_fail("service endpoint binding has no terminal attachment")

        matching_interfaces: List[Dict[str, Any]] = []
        for interface in interfaces.values():
            if not isinstance(interface, dict):
                continue
            backing_ref = interface.get("backingRef")
            if (
                isinstance(backing_ref, dict)
                and backing_ref.get("id") == terminal_attachment
            ):
                matching_interfaces.append(interface)
        if len(matching_interfaces) != 1:
            _dns_renderer_fail(
                "service endpoint terminal attachment does not resolve to one runtime interface"
            )

        runtime_ifname = matching_interfaces[0].get("runtimeIfName")
        if not isinstance(runtime_ifname, str) or not runtime_ifname:
            _dns_renderer_fail(
                "service endpoint terminal attachment has no runtime interface"
            )

        materialized_addresses = set()
        for key in ("addr4", "addr6"):
            value = matching_interfaces[0].get(key)
            if value is None:
                continue
            if not isinstance(value, str) or not value:
                _dns_renderer_fail(
                    "service endpoint terminal attachment has malformed interface addressing"
                )
            try:
                materialized_addresses.add(ip_interface(value).ip)
            except ValueError:
                _dns_renderer_fail(
                    "service endpoint terminal attachment has malformed interface addressing"
                )

        addresses = binding.get("addresses", [])
        if not isinstance(addresses, list):
            _dns_renderer_fail("service endpoint binding has malformed addresses")
        for value in addresses:
            if not isinstance(value, str) or not value:
                _dns_renderer_fail("service endpoint binding has malformed addresses")
            try:
                parsed = ip_address(value)
            except ValueError:
                _dns_renderer_fail("service endpoint binding has malformed addresses")
            if parsed in materialized_addresses:
                continue
            family = "ip -6" if parsed.version == 6 else "ip"
            prefix = 128 if parsed.version == 6 else 32
            command = (
                f"{family} addr replace {shlex.quote(f'{parsed}/{prefix}')} "
                f"dev {shlex.quote(runtime_ifname)}"
            )
            if command not in commands:
                commands.append(command)

    return commands


def _public_resolver_drop_commands(
    dns: Dict[str, Any], forwarders: List[str] | None = None
) -> List[str]:
    kill_switch = dns.get("killSwitch")
    if not isinstance(kill_switch, dict) or not kill_switch.get("blockPublicResolvers"):
        return []

    denied_cidrs = _string_list(dns.get("deniedResolverCidrs", []))
    if not denied_cidrs:
        return []

    # CPM_AUTHORITY FS-310-HDS-010-SDS-010-SMS-130:
    # The DNS guard table/chain names are renderer implementation details.
    # Policy (which resolvers to block) comes from CPM 'killSwitch' and
    # 'deniedResolverCidrs' fields. The renderer materializes CPM DNS
    # policy into nftables grammar.
    commands = [
        "nft add table inet clab_dns_guard 2>/dev/null || true",
        "nft add chain inet clab_dns_guard forward '{ type filter hook forward priority -50; policy accept; }' 2>/dev/null || true",
        "nft add chain inet clab_dns_guard output '{ type filter hook output priority -50; policy accept; }' 2>/dev/null || true",
        "nft flush chain inet clab_dns_guard forward",
        "nft flush chain inet clab_dns_guard output",
    ]

    effective_forwarders = (
        forwarders
        if forwarders is not None
        else _string_list(dns.get("forwarders") or dns.get("upstreams") or [])
    )
    outgoing_interfaces = _string_list(dns.get("outgoingInterfaces", []))
    for source in outgoing_interfaces:
        source_family = "ip6" if ":" in source else "ip"
        for forwarder in effective_forwarders:
            forwarder_family = "ip6" if ":" in forwarder else "ip"
            if source_family != forwarder_family:
                continue
            commands.append(
                f"nft add rule inet clab_dns_guard output {source_family} saddr {_nft_literal(source)} "
                f"{forwarder_family} daddr {_nft_literal(forwarder)} udp dport 53 "
                f"accept comment {shlex.quote('allow-dns-service-egress')}"
            )
            commands.append(
                f"nft add rule inet clab_dns_guard output {source_family} saddr {_nft_literal(source)} "
                f"{forwarder_family} daddr {_nft_literal(forwarder)} tcp dport 53 "
                f"accept comment {shlex.quote('allow-dns-service-egress')}"
            )

    for cidr in denied_cidrs:
        family = "ip6" if ":" in cidr else "ip"
        literal = _nft_literal(cidr)
        for hook, comment in (
            ("forward", "deny-public-dns-forward-leak"),
            ("output", "deny-public-dns-output-leak"),
        ):
            commands.append(
                f"nft add rule inet clab_dns_guard {hook} {family} daddr {literal} "
                f"udp dport 53 drop comment {shlex.quote(comment)}"
            )
            commands.append(
                f"nft add rule inet clab_dns_guard {hook} {family} daddr {literal} "
                f"tcp dport 53 drop comment {shlex.quote(comment)}"
            )

    return commands


def _dns_input_commands(dns: Dict[str, Any], authority: Dict[str, Any]) -> List[str]:
    listeners = []
    for value in _string_list(dns.get("listen", [])):
        try:
            parsed = ip_address(value)
        except ValueError:
            _dns_renderer_fail("DNS listener input has malformed addressing")
        if not parsed.is_loopback and parsed not in listeners:
            listeners.append(parsed)

    requester_prefixes = list(_string_list(dns.get("allowFrom", [])))
    for policy in authority["requesterPolicies"]:
        requester_prefixes.extend(_string_list(policy.get("sourcePrefixes", [])))

    networks = []
    for value in requester_prefixes:
        try:
            parsed = ip_network(value, strict=False)
        except ValueError:
            _dns_renderer_fail("DNS requester input has malformed addressing")
        if parsed not in networks:
            networks.append(parsed)

    rules: List[str] = []
    for network in networks:
        family = "ip6" if network.version == 6 else "ip"
        for listener in listeners:
            if listener.version != network.version:
                continue
            for protocol in ("udp", "tcp"):
                rules.append(
                    f"nft insert rule inet filter input {family} saddr {_nft_literal(str(network))} "
                    f"{family} daddr {_nft_literal(str(listener))} {protocol} dport 53 "
                    "accept comment s88-dns-service-input"
                )

    if not rules:
        return []

    return [
        "nft -a list chain inet filter input >/dev/null",
        "while :; do",
        "  handle=\"$(nft -a list chain inet filter input | awk '/comment \\\"s88-dns-service-input\\\"/ { print $NF; exit }')\"",
        '  if [ -z "$handle" ]; then break; fi',
        '  nft delete rule inet filter input handle "$handle"',
        "done",
        *rules,
    ]


def _dns_egress_policy_commands(node: Dict[str, Any]) -> List[str]:
    policy = normalize_dns_egress_policy(node)
    if policy is None:
        return []

    mark = policy["firewallMark"]
    priority = policy["rulePriority"]
    table = policy["tableId"]
    return [
        "if nft list table inet s88_dns_egress >/dev/null 2>&1; then nft delete table inet s88_dns_egress; fi",
        "nft add table inet s88_dns_egress",
        "nft 'add chain inet s88_dns_egress output { type route hook output priority mangle; policy accept; }'",
        f"nft add rule inet s88_dns_egress output meta l4proto udp udp dport 53 meta mark set {mark} comment 'select-modeled-dns-egress'",
        f"nft add rule inet s88_dns_egress output meta l4proto tcp tcp dport 53 meta mark set {mark} comment 'select-modeled-dns-egress'",
        'dns_service_uid="$(id -u unbound)"',
        f'while ip rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto udp dport 53 priority {priority} table {table} 2>/dev/null; do :; done',
        f'while ip rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto tcp dport 53 priority {priority} table {table} 2>/dev/null; do :; done',
        f'while ip rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" priority {priority} table {table} 2>/dev/null; do :; done',
        f'ip rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto udp dport 53 priority {priority} table {table}',
        f'ip rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto tcp dport 53 priority {priority} table {table}',
        f'while ip -6 rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto udp dport 53 priority {priority} table {table} 2>/dev/null; do :; done',
        f'while ip -6 rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto tcp dport 53 priority {priority} table {table} 2>/dev/null; do :; done',
        f'while ip -6 rule del uidrange "${{dns_service_uid}}-${{dns_service_uid}}" priority {priority} table {table} 2>/dev/null; do :; done',
        f'ip -6 rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto udp dport 53 priority {priority} table {table}',
        f'ip -6 rule add uidrange "${{dns_service_uid}}-${{dns_service_uid}}" ipproto tcp dport 53 priority {priority} table {table}',
        f"while ip rule del fwmark {mark} priority {priority} table {table} 2>/dev/null; do :; done",
        f"ip rule add fwmark {mark} priority {priority} table {table} 2>/dev/null || true",
        f"while ip -6 rule del fwmark {mark} priority {priority} table {table} 2>/dev/null; do :; done",
        f"ip -6 rule add fwmark {mark} priority {priority} table {table} 2>/dev/null || true",
    ]


def render_dns_service(
    node: Dict[str, Any],
    node_name: str = "container",
) -> List[str]:
    services = node.get("services")
    if not isinstance(services, dict):
        return []

    dns = services.get("dns")
    if not isinstance(dns, dict):
        return []

    listen = _string_list(dns.get("listen", []))
    if not listen:
        return []

    authority = normalize_dns_authority(dns)
    if authority["recursionMode"] is not None:
        validation_authority = authority["validationAuthority"]
        if validation_authority is not None:
            egress_policy = normalize_dns_egress_policy(node)
            if egress_policy is None or egress_policy.get(
                "selectedUplink"
            ) != validation_authority.get("selectedUplink"):
                _dns_validation_fail(
                    "the controlled authority does not match the model-owned DNS egress selection"
                )
        return render_unbound_dns_service(
            dns,
            authority,
            _service_endpoint_address_commands(node, dns)
            + _dns_input_commands(dns, authority)
            + _public_resolver_drop_commands(dns, authority["rootForwarders"])
            + _dns_egress_policy_commands(node),
        )

    payload = {
        "listen": ["127.0.0.1", "::1"] + listen,
        "forwarders": _string_list(dns.get("forwarders") or dns.get("upstreams") or []),
        "outgoingInterfaces": _string_list(dns.get("outgoingInterfaces", [])),
        "localRecords": _local_records(dns.get("localRecords", [])),
    }

    # GAMP: FS-540-HDS-010-SDS-010-SMS-035 self-referential forwarder guard.
    # If a forwarder address matches a non-loopback listen address, the DNS proxy
    # would forward queries to itself, creating a forwarding loop.
    _nonLoopback = set(listen)
    _selfRef = [f for f in payload["forwarders"] if f in _nonLoopback]
    if _selfRef:
        raise ValueError(
            "CLAB DNS renderer DNS_RENDERER_CONTRACT_DIVERGENCE: "
            "self-referential forwarder rejected without logging address material; "
            "GAMP: FS-540-HDS-010-SDS-010-SMS-035"
        )
    namespace_fallback = _namespace_fallback(dns.get("namespaceFallback", {}))
    if namespace_fallback:
        payload["namespaceFallback"] = namespace_fallback
    public_resolver_drop_script = "\n".join(_public_resolver_drop_commands(dns))
    if public_resolver_drop_script:
        public_resolver_drop_script += "\n"

    return [
        _sh(
            "pkill -f '^python3 /tmp/clabgen-dns-proxy.py' >/dev/null 2>&1 || true\n"
            + public_resolver_drop_script
            + "cat >/etc/resolv.conf <<'RESOLV'\n"
            "nameserver 127.0.0.1\n"
            "nameserver ::1\n"
            "options timeout:1 attempts:2\n"
            "RESOLV\n"
            "cat >/tmp/clabgen-dns-proxy.json <<'JSON'\n"
            + json.dumps(payload, indent=2, sort_keys=True)
            + "\nJSON\n"
            "cat >/tmp/dns_proxy_protocol.py <<'PY'\n"
            + PROTOCOL_SCRIPT.read_text()
            + "PY\n"
            "cat >/tmp/clabgen-dns-proxy.py <<'PY'\n"
            + RUNTIME_SCRIPT.read_text()
            + "PY\n"
            "nohup python3 /tmp/clabgen-dns-proxy.py /tmp/clabgen-dns-proxy.json "
            ">/tmp/clabgen-dns-proxy.log 2>&1 &\n"
        )
    ]


def render_dns_resolver_config(
    node: Dict[str, Any],
    node_name: str = "container",
) -> List[str]:
    """Materialize CPM per-interface dnsResolver authority into resolv.conf."""
    services = node.get("services")
    dns_service = services.get("dns") if isinstance(services, dict) else None
    if isinstance(dns_service, dict) and _string_list(dns_service.get("listen", [])):
        return []

    resolvers = _dns_resolvers(node)
    if not resolvers:
        return []

    nameservers: List[str] = []
    sources: List[str] = []
    for resolver in resolvers:
        source = resolver.get("resolverSource")
        if isinstance(source, str) and source:
            sources.append(source)
        for key in ("resolver4", "resolver6"):
            value = resolver.get(key)
            if isinstance(value, str) and value and value not in nameservers:
                nameservers.append(value)

    materialized_sources = {
        "local-recursive",
        "upstream-forwarder",
        "public-fallback",
        "none",
    }
    if not nameservers and not any(
        source in materialized_sources for source in sources
    ):
        return []

    lines = [
        "# Generated by network-renderer-containerlab-linux-backend",
        "# GAMP: FS-540-HDS-010-SDS-010-SMS-020",
    ]
    if nameservers:
        lines.extend(f"nameserver {address}" for address in nameservers)
    else:
        lines.append("# No nameserver emitted by CPM dnsResolver authority.")
    lines.append("options timeout:1 attempts:1")

    return [_sh("cat >/etc/resolv.conf <<'RESOLV'\n" + "\n".join(lines) + "\nRESOLV\n")]


def _dns_resolvers(node: Dict[str, Any]) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []

    interfaces = node.get("interfaces")
    if isinstance(interfaces, dict):
        for iface in interfaces.values():
            if not isinstance(iface, dict):
                continue
            resolver = iface.get("dnsResolver")
            if isinstance(resolver, dict):
                result.append(resolver)

    runtime = node.get("effectiveRuntimeRealization")
    if not isinstance(runtime, dict):
        return result

    runtime_interfaces = runtime.get("interfaces")
    if not isinstance(runtime_interfaces, dict):
        return result

    for iface in runtime_interfaces.values():
        if not isinstance(iface, dict):
            continue
        resolver = iface.get("dnsResolver")
        if isinstance(resolver, dict):
            result.append(resolver)
    return result


def _string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []

    result: List[str] = []
    for item in value:
        if isinstance(item, str) and item:
            result.append(item)
    return result


def _local_records(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        return []

    records: List[Dict[str, Any]] = []
    for record in value:
        if not isinstance(record, dict):
            continue
        record_name = record.get("name")
        if isinstance(record_name, str) and record_name:
            records.append(record)
    return records


def _namespace_fallback(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        return {}

    decisions = []
    for decision in value.get("decisions", []):
        if not isinstance(decision, dict):
            continue
        namespace = decision.get("namespace")
        action = decision.get("action")
        if not isinstance(namespace, str) or not namespace:
            continue
        if action not in ("block", "deny", "fallback", "answer"):
            continue
        decisions.append(
            {
                "requesterScope": decision.get("requesterScope"),
                "namespace": namespace,
                "allowedRecordClasses": _string_list(
                    decision.get("allowedRecordClasses", [])
                ),
                "deniedRecordClasses": _string_list(
                    decision.get("deniedRecordClasses", [])
                ),
                "failedAnswerReason": decision.get("failedAnswerReason"),
                "action": action,
                "publicRecursionFallback": bool(
                    decision.get("publicRecursionFallback", False)
                ),
                "leakPrevention": decision.get("leakPrevention"),
                "fallbackTarget": decision.get("fallbackTarget"),
            }
        )

    if not decisions:
        return {}

    return {
        "defaultPublicRecursionFallback": bool(
            value.get("defaultPublicRecursionFallback", False)
        ),
        "decisions": decisions,
    }
