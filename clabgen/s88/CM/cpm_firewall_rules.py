from __future__ import annotations

import json
import shlex
from typing import Any, Dict, List


def _family_prefixes(
    rule_obj: Dict[str, Any], field: str, family: int
) -> List[str]:
    values = rule_obj.get(field)
    if not isinstance(values, list):
        return []

    prefixes: List[str] = []
    for value in values:
        prefix = None
        prefix_family = family
        if isinstance(value, str):
            prefix = value
            prefix_family = 6 if ":" in value else 4
        elif isinstance(value, dict):
            raw_prefix = value.get("prefix")
            raw_family = value.get("family")
            if isinstance(raw_prefix, str) and raw_prefix:
                prefix = raw_prefix
            if raw_family in (4, 6):
                prefix_family = raw_family

        if prefix is not None and prefix_family == family:
            prefixes.append(prefix)

    return prefixes


def _prefix_expr(prefixes: List[str]) -> str:
    if len(prefixes) == 1:
        return prefixes[0]
    return "{ " + ", ".join(prefixes) + " }"


def _match_family_applies(match: Dict[str, Any], family: int) -> bool:
    match_family = match.get("family", "any")
    if match_family == "any":
        return True
    if match_family in (family, str(family)):
        return True
    if family == 4 and match_family in ("ipv4", "ip"):
        return True
    if family == 6 and match_family in ("ipv6", "ip6"):
        return True
    return False


def _dports_expr(match: Dict[str, Any]) -> str:
    raw_dports = match.get("dports")
    if raw_dports is None:
        return ""
    if isinstance(raw_dports, int):
        return f" dport {raw_dports}"
    if not isinstance(raw_dports, list):
        return ""

    ports: List[str] = []
    for raw_port in raw_dports:
        if isinstance(raw_port, int):
            ports.append(str(raw_port))
    if not ports:
        return ""
    if len(ports) == 1:
        return f" dport {ports[0]}"
    return " dport { " + ", ".join(ports) + " }"


def _match_suffix(match: Dict[str, Any], family: int) -> str | None:
    if not _match_family_applies(match, family):
        return None

    proto = match.get("proto")
    proto_text = "" if proto in (None, "any") else str(proto).lower()
    dports = _dports_expr(match)

    if proto_text in ("icmp", "icmpv4"):
        if proto_text == "icmpv4" and family != 4:
            raise ValueError("IPv4 ICMP match cannot be rendered for IPv6")
        return f" meta l4proto {'icmpv6' if family == 6 else 'icmp'}"
    if proto_text in ("icmpv6", "ipv6-icmp"):
        if family != 6:
            raise ValueError("IPv6 ICMP match cannot be rendered for IPv4")
        return " meta l4proto icmpv6"
    if proto_text:
        return f" {proto_text}{dports}"
    return dports


def _explicit_match_suffixes(rule_obj: Dict[str, Any], family: int) -> List[str]:
    matches = rule_obj.get("matches")
    if not isinstance(matches, list):
        return []

    suffixes: List[str] = []
    for match in matches:
        if not isinstance(match, dict):
            continue
        suffix = _match_suffix(match, family)
        if suffix is not None:
            suffixes.append(suffix)
    return suffixes


def _identity_comment(rule_obj: Dict[str, Any]) -> str:
    for field in ("relationId", "policyId", "sourceRelationId", "comment"):
        value = rule_obj.get(field)
        if isinstance(value, str) and value:
            return f" comment {json.dumps(value)}"
    return ""


def _connection_state_expr(rule_obj: Dict[str, Any]) -> str:
    state = rule_obj.get("connectionState")
    is_return_rule = rule_obj.get("returnRule") is True

    if state in (None, ""):
        if is_return_rule:
            relation_id = rule_obj.get("relationId") or "<unknown>"
            raise ValueError(
                "FS-230-HDS-010-SDS-010-SMS-030: reverse return rule "
                f"{relation_id!r} carries no connection-state restriction "
                "(reverse-new-flow authority invention)"
            )
        return ""

    if state != "established,related":
        relation_id = rule_obj.get("relationId") or "<unknown>"
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-030: forwarding rule "
            f"{relation_id!r} carries unsupported connectionState {state!r}"
        )

    return " ct state established,related"


def _runtime_destination_rule(
    rule_obj: Dict[str, Any],
    from_interface: str,
    to_interface: str,
    action: str,
    connection_state: str,
) -> str | None:
    raw_destinations = rule_obj.get("destinationRuntimeAddresses")
    if raw_destinations in (None, []):
        return None
    if not isinstance(raw_destinations, list) or len(raw_destinations) != 1:
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime IPv6 destination "
            "owner is missing or ambiguous"
        )
    if rule_obj.get("destinationPrefixes") not in (None, []):
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: protected runtime and static "
            "destinations cannot coexist"
        )
    if (
        rule_obj.get("returnBehavior") != "stateful-return"
        or rule_obj.get("translationMode") != "none"
        or rule_obj.get("sourcePreservation") != "preserve-source"
        or rule_obj.get("destinationTranslation") is not False
    ):
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime IPv6 destination lacks "
            "no-translation preserve-source stateful-return authority"
        )

    destination = raw_destinations[0]
    if not isinstance(destination, dict):
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime IPv6 destination is malformed"
        )
    source_file = destination.get("sourceFile")
    interface_identifier = destination.get("interfaceIdentifier")
    delegated_length = destination.get("delegatedPrefixLength")
    tenant_length = destination.get("perTenantPrefixLength")
    slot = destination.get("slot")
    if (
        destination.get("sourceClass") != "protected"
        or not isinstance(source_file, str)
        or not source_file.startswith("/run/secrets/")
        or source_file == "/run/secrets/"
        or "/../" in source_file
        or not isinstance(interface_identifier, str)
        or not interface_identifier
        or not isinstance(delegated_length, int)
        or not isinstance(tenant_length, int)
        or not isinstance(slot, int)
        or destination.get("targetPrefixLength") != 128
    ):
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: incomplete protected runtime "
            "IPv6 destination contract"
        )

    matches = rule_obj.get("matches")
    if not isinstance(matches, list) or len(matches) != 1:
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime destination requires "
            "one exact IPv6 transport match"
        )
    match = matches[0]
    dports = match.get("dports") if isinstance(match, dict) else None
    if (
        not isinstance(match, dict)
        or match.get("family") != "ipv6"
        or match.get("proto") not in ("tcp", "udp")
        or not isinstance(dports, list)
        or len(dports) != 1
        or not isinstance(dports[0], int)
    ):
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime destination transport "
            "match is incomplete"
        )

    protocol = match["proto"]
    destination_port = dports[0]
    comment = _identity_comment(rule_obj)
    if not comment:
        raise ValueError(
            "FS-230-HDS-010-SDS-010-SMS-040: runtime destination has no "
            "deterministic rule owner"
        )
    materializer = " ".join(
        [
            "clab-protected-ipv6-materializer",
            "--source",
            shlex.quote(source_file),
            "--delegated-prefix-length",
            str(delegated_length),
            "--tenant-prefix-length",
            str(tenant_length),
            "--slot",
            str(slot),
            "--interface-identifier",
            shlex.quote(interface_identifier),
        ]
    )
    script = "\n".join(
        [
            "set -eu",
            f'runtime_address="$({materializer})"',
            (
                "nft add rule inet fw forward "
                f"iifname {shlex.quote(from_interface)} "
                f"oifname {shlex.quote(to_interface)}"
                f"{connection_state} meta nfproto ipv6 "
                'ip6 daddr "$runtime_address" '
                f"meta l4proto {protocol} {protocol} dport {destination_port} "
                f"counter {action}{comment}"
            ),
        ]
    )
    return f"sh -eu -c {shlex.quote(script)}"


def rules_for_cpm_rule(rule_obj: Dict[str, Any]) -> List[str]:
    from_interface = rule_obj.get("fromInterface")
    to_interface = rule_obj.get("toInterface")
    if not isinstance(from_interface, str) or not from_interface:
        return []
    if not isinstance(to_interface, str) or not to_interface:
        return []

    action = "accept" if rule_obj.get("action") == "accept" else "drop"
    traffic_type = rule_obj.get("trafficType")
    family = rule_obj.get("family")
    families = [family] if family in (4, 6) else [4, 6]
    comment = _identity_comment(rule_obj)
    connection_state = _connection_state_expr(rule_obj)

    runtime_rule = _runtime_destination_rule(
        rule_obj,
        from_interface,
        to_interface,
        action,
        connection_state,
    )
    if runtime_rule is not None:
        return [runtime_rule]

    rules: List[str] = []
    raw_matches = rule_obj.get("matches")
    has_explicit_matches = isinstance(raw_matches, list) and raw_matches != []
    has_destination_prefixes = isinstance(
        rule_obj.get("destinationPrefixes"), list
    ) and rule_obj["destinationPrefixes"] != []
    for rule_family in families:
        source_part = ""
        source_prefixes = _family_prefixes(rule_obj, "sourcePrefixes", rule_family)
        if source_prefixes:
            source_part = (
                f" ip{'6' if rule_family == 6 else ''} saddr "
                f"{_prefix_expr(source_prefixes)}"
            )
        destination_part = ""
        destination_prefixes = _family_prefixes(
            rule_obj, "destinationPrefixes", rule_family
        )
        if has_destination_prefixes and not destination_prefixes:
            continue
        if destination_prefixes:
            destination_part = (
                f" ip{'6' if rule_family == 6 else ''} daddr "
                f"{_prefix_expr(destination_prefixes)}"
            )

        base = (
            "add rule inet fw forward "
            f"iifname {json.dumps(from_interface)} "
            f"oifname {json.dumps(to_interface)}"
            f"{connection_state}"
            f"{source_part}"
            f"{destination_part}"
        )

        match_suffixes = _explicit_match_suffixes(rule_obj, rule_family)
        if match_suffixes:
            for suffix in match_suffixes:
                statement = f"{base}{suffix} counter {action}{comment}"
                rules.append(f"nft {shlex.quote(statement)}")
        elif has_explicit_matches:
            continue
        elif traffic_type == "dns":
            udp_statement = f"{base} udp dport 53 counter {action}{comment}"
            tcp_statement = f"{base} tcp dport 53 counter {action}{comment}"
            rules.append(f"nft {shlex.quote(udp_statement)}")
            rules.append(f"nft {shlex.quote(tcp_statement)}")
        else:
            statement = f"{base} counter {action}{comment}"
            rules.append(f"nft {shlex.quote(statement)}")

    return rules
