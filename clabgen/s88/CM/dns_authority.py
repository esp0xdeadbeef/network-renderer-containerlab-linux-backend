from __future__ import annotations

from typing import Any, Dict, List


_ALLOWED_RECURSION_MODES = {"iterative", "forwarding", "local-only"}
_NON_FATAL_WARNING_CODES = {"DNS_CORE_UPSTREAM_HARDCODED"}


def _string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item]


def _dict_list(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _sorted_unique(values: List[str]) -> List[str]:
    return sorted(set(values))


def _family_complete(values: List[str]) -> bool:
    return any("." in value for value in values) and any(
        ":" in value for value in values
    )


def _non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _fail(code: str, reason: str) -> None:
    raise ValueError(
        f"CLAB DNS {code}: {reason}; address material is intentionally omitted"
    )


def normalize_dns_authority(dns: Dict[str, Any]) -> Dict[str, Any]:
    raw_mode = dns.get("recursionMode")
    if raw_mode is None:
        recursion_mode = None
    elif isinstance(raw_mode, str) and raw_mode in _ALLOWED_RECURSION_MODES:
        recursion_mode = raw_mode
    else:
        _fail(
            "DNS_RECURSION_MODE_INVALID",
            "CPM emitted an unsupported recursion mode",
        )

    reproducibility_warnings = _dict_list(dns.get("reproducibilityWarnings", []))
    warning_codes = _sorted_unique(
        [
            warning["code"]
            for warning in reproducibility_warnings
            if isinstance(warning.get("code"), str) and warning["code"]
        ]
    )
    fatal_warning_codes = [
        code for code in warning_codes if code not in _NON_FATAL_WARNING_CODES
    ]
    if fatal_warning_codes:
        _fail(
            ",".join(fatal_warning_codes),
            "CPM marked this resolver contract non-reproducible",
        )

    legacy_forwarders = _string_list(
        dns.get("forwarders") or dns.get("upstreams") or []
    )
    upstream_resolvers = _dict_list(dns.get("upstreamResolvers", []))
    named_core_resolvers = [
        resolver
        for resolver in upstream_resolvers
        if resolver.get("kind") == "named-core-resolver"
    ]
    valid_named_core_resolvers = all(
        isinstance(resolver.get("endpointAuthority"), dict)
        and _non_empty_string(resolver["endpointAuthority"].get("relationId"))
        and _non_empty_string(
            resolver["endpointAuthority"].get("terminalAttachmentId")
        )
        for resolver in named_core_resolvers
    )
    named_core_addresses = _sorted_unique(
        [
            address
            for resolver in named_core_resolvers
            for address in _string_list(resolver.get("addresses", []))
        ]
    )
    local_authority_resolvers = [
        resolver
        for resolver in upstream_resolvers
        if resolver.get("kind") == "local-namespace-authority"
    ]

    service_endpoint_bindings = _dict_list(
        dns.get("serviceEndpointBindings", [])
    )
    valid_service_endpoint_bindings = all(
        _non_empty_string(binding.get("service"))
        and _non_empty_string(binding.get("requesterService"))
        and _non_empty_string(binding.get("providerNode"))
        and _non_empty_string(binding.get("relationId"))
        and _non_empty_string(binding.get("terminalAttachmentId"))
        and _family_complete(_string_list(binding.get("addresses", [])))
        for binding in service_endpoint_bindings
    )
    service_endpoint_addresses = _sorted_unique(
        [
            address
            for binding in service_endpoint_bindings
            for address in _string_list(binding.get("addresses", []))
        ]
    )
    configured_listen_addresses = _sorted_unique(
        _string_list(dns.get("listen", []))
    )
    if service_endpoint_bindings and not (
        valid_service_endpoint_bindings
        and service_endpoint_addresses == configured_listen_addresses
    ):
        _fail(
            "DNS_RENDERER_CONTRACT_DIVERGENCE",
            "provider listener addresses or terminal authority disagree with the CPM service endpoint binding",
        )

    local_forward_zones = _dict_list(dns.get("localForwardZones", []))
    valid_local_forward_zones = all(
        isinstance(zone.get("name"), str)
        and bool(zone["name"])
        and isinstance(zone.get("relationId"), str)
        and bool(zone["relationId"])
        and zone.get("forwardFirst") is False
        and _family_complete(_string_list(zone.get("forwardTo", [])))
        for zone in local_forward_zones
    )
    forwarded_namespaces = {
        zone["name"]
        for zone in local_forward_zones
        if _non_empty_string(zone.get("name"))
    }
    shadowed_local_namespaces = [
        zone["name"]
        for zone in _dict_list(dns.get("localZones", []))
        if _non_empty_string(zone.get("name"))
        and zone["name"] in forwarded_namespaces
        and zone.get("type", "static") != "transparent"
    ]
    if shadowed_local_namespaces:
        _fail(
            "DNS_LOCAL_NAMESPACE_SHADOWED",
            "a local zone would terminate a namespace before its modeled forwarding authority",
        )

    requester_policies = _dict_list(dns.get("requesterPolicies", []))
    valid_requester_policies = all(
        policy.get("action") == "refuse_non_local"
        and isinstance(policy.get("requesterService"), str)
        and bool(policy["requesterService"])
        and isinstance(policy.get("relationId"), str)
        and bool(policy["relationId"])
        and bool(_string_list(policy.get("sourcePrefixes", [])))
        and bool(_string_list(policy.get("namespaces", [])))
        for policy in requester_policies
    )
    if not valid_requester_policies:
        _fail(
            "DNS_LOCAL_ONLY_AUTHORITY_LEAK",
            "a provider requester policy is not source-scoped refuse_non_local",
        )

    local_only_policy = dns.get("localOnlyPolicy")
    valid_local_only_policy = (
        isinstance(local_only_policy, dict)
        and isinstance(local_only_policy.get("providerService"), str)
        and bool(local_only_policy["providerService"])
        and isinstance(local_only_policy.get("relationId"), str)
        and bool(local_only_policy["relationId"])
        and bool(_string_list(local_only_policy.get("namespaces", [])))
        and local_only_policy.get("recursion") is False
        and local_only_policy.get("publicFallback") is False
        and local_only_policy.get("transitiveEgress") is False
        and local_only_policy.get("missAction") == "refuse"
    )

    if recursion_mode == "forwarding":
        if not (
            len(named_core_resolvers) == 1
            and valid_named_core_resolvers
            and _family_complete(named_core_addresses)
            and (
                not legacy_forwarders
                or _sorted_unique(legacy_forwarders) == named_core_addresses
            )
        ):
            _fail(
                "DNS_RENDERER_CONTRACT_DIVERGENCE",
                "forwarding mode lacks one dual-stack named-core resolver or disagrees with the legacy projection",
            )
        root_forwarders = named_core_addresses
    elif recursion_mode == "iterative":
        if legacy_forwarders or named_core_resolvers:
            _fail(
                "DNS_RECURSION_MODE_INVALID",
                "iterative mode contains a forwarding or fallback source",
            )
        root_forwarders = []
    elif recursion_mode == "local-only":
        if not (
            not legacy_forwarders
            and len(local_authority_resolvers) == 1
            and bool(local_forward_zones)
            and valid_local_forward_zones
            and valid_local_only_policy
        ):
            _fail(
                "DNS_LOCAL_ONLY_AUTHORITY_LEAK",
                "local-only mode is incomplete or would permit recursion, fallback, or transitive egress",
            )
        root_forwarders = []
    else:
        root_forwarders = legacy_forwarders

    return {
        "recursionMode": recursion_mode,
        "reproducibilityWarnings": reproducibility_warnings,
        "warningCodes": warning_codes,
        "rootForwarders": root_forwarders,
        "localForwardZones": local_forward_zones,
        "requesterPolicies": requester_policies,
        "localOnlyPolicy": local_only_policy
        if isinstance(local_only_policy, dict)
        else {},
    }


def normalize_dns_egress_policy(node: Dict[str, Any]) -> Dict[str, Any] | None:
    runtime_origin = node.get("runtimeOriginEgress")
    if not isinstance(runtime_origin, dict):
        return None

    raw_policy = runtime_origin.get("policyRouting")
    policy_required = runtime_origin.get("policyRoutingRequired") is True
    if not policy_required and not isinstance(raw_policy, dict):
        return None

    if not (
        runtime_origin.get("enabled") is True
        and runtime_origin.get("source") == "dns-service"
        and isinstance(raw_policy, dict)
    ):
        _fail(
            "DNS_RENDERER_CONTRACT_DIVERGENCE",
            "CPM DNS runtime-origin egress lacks one complete model-owned policy-routing selection",
        )

    interfaces = node.get("interfaces")
    if not isinstance(interfaces, dict):
        interfaces = {}

    selected_interface_name = raw_policy.get("selectedInterface")
    selected_interface = interfaces.get(selected_interface_name)
    if not isinstance(selected_interface, dict):
        selected_interface = {}
    allocation = selected_interface.get("policyRoutingAllocation")
    if not isinstance(allocation, dict):
        allocation = {}

    selected_uplink = raw_policy.get("selectedUplink")
    runtime_if_name = raw_policy.get("runtimeIfName")
    table_id = raw_policy.get("tableId")
    rule_priority = raw_policy.get("rulePriority")
    firewall_mark = raw_policy.get("firewallMark")
    complete = (
        raw_policy.get("source") == "control-plane-model"
        and _non_empty_string(selected_uplink)
        and runtime_origin.get("uplinks") == [selected_uplink]
        and _non_empty_string(selected_interface_name)
        and selected_interface.get("kind", selected_interface.get("sourceKind"))
        == "wan"
        and _non_empty_string(runtime_if_name)
        and selected_interface.get(
            "runtimeIfName", selected_interface.get("renderedIfName")
        )
        == runtime_if_name
        and allocation.get("source") == "control-plane-model"
        and isinstance(table_id, int)
        and not isinstance(table_id, bool)
        and table_id > 0
        and allocation.get("tableId") == table_id
        and isinstance(rule_priority, int)
        and not isinstance(rule_priority, bool)
        and rule_priority > 0
        and allocation.get("tableRulePriority") == rule_priority
        and isinstance(firewall_mark, int)
        and not isinstance(firewall_mark, bool)
        and firewall_mark > 0
    )
    if not complete:
        _fail(
            "DNS_RENDERER_CONTRACT_DIVERGENCE",
            "CPM DNS runtime-origin egress lacks one complete model-owned policy-routing selection",
        )

    return dict(raw_policy)
