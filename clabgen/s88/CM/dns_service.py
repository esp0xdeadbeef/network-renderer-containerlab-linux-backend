from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List
import json
import shlex


RUNTIME_SCRIPT = Path(__file__).with_name("dns_proxy_runtime.py")
PROTOCOL_SCRIPT = Path(__file__).with_name("dns_proxy_protocol.py")


def _sh(script: str) -> str:
    return "sh -c " + shlex.quote(script)


def _nft_literal(value: str) -> str:
    return shlex.quote(value)


def _public_resolver_drop_commands(dns: Dict[str, Any]) -> List[str]:
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
            "CLAB DNS renderer rejects self-referential forwarder: "
            + "; ".join(
                f"forward-addr {f} matches listen address on {node_name}"
                for f in _selfRef
            )
            + ". GAMP: FS-540-HDS-010-SDS-010-SMS-035"
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
    if not nameservers and not any(source in materialized_sources for source in sources):
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

    return [
        _sh(
            "cat >/etc/resolv.conf <<'RESOLV'\n"
            + "\n".join(lines)
            + "\nRESOLV\n"
        )
    ]


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
