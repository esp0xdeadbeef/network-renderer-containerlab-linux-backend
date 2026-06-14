from __future__ import annotations

from typing import Any, Dict, List, Optional

# GAMP: FS-540-HDS-020-SDS-010-SMS-010
# CLAB Recursive DNS Requester Fixture Module
#
# Consumes modeled requester-fixture data and emits a CLAB requester fixture
# contract. Rejects missing, wrong-surface, hardcoded, and host-injected
# substitutes before renderer materialization.

# Valid access-surface kinds (from SMS Module Failure Conditions line 44:
# "attaches to a management, provider, underlay, WAN, or host-only surface
# instead of the modeled access attachment"). Access surfaces are tenant-kind.
_VALID_ACCESS_SURFACE_KINDS = {"tenant"}

# Hardcoded public DNS resolvers that indicate host-injected behavior.
# These are well-known public resolvers that, when present in the requester
# fixture resolver field, indicate a hardcoded DNS address rather than one
# derived from the modeled FS-540 recursive DNS relationship.
_HARDCODED_PUBLIC_RESOLVERS = frozenset(
    {
        "8.8.8.8",
        "8.8.4.4",
        "1.1.1.1",
        "1.0.0.1",
        "9.9.9.9",
        "149.112.112.112",
        "208.67.222.222",
        "208.67.220.220",
    }
)

# Resolver source values that indicate host-side policy injection
# (host resolver file, public DNS defaults, hardcoded, DHCP).
_HOST_SIDE_SOURCES = frozenset(
    {
        "host-resolver",
        "public-dns-default",
        "hardcoded",
        "dhcp",
    }
)


def _is_public_hardcoded(address: str) -> bool:
    """Check if an address is a well-known hardcoded public DNS resolver."""
    from ipaddress import ip_address

    try:
        ip = ip_address(address)
        return str(ip) in _HARDCODED_PUBLIC_RESOLVERS
    except ValueError:
        return False


def render_dns_requester_fixture(
    requester_fixture: Dict[str, Any],
    *,
    access_attachment: Optional[Dict[str, Any]] = None,
    modeled_resolvers: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """Emit CLAB requester fixture contract or raise ValueError with diagnostic.

    Args:
        requester_fixture: Modeled requester fixture data containing at minimum
            ``requesterScope``, ``resolver``, ``resolverSource``,
            ``defaultRoute``, and optionally ``requesterIdentity``.
        access_attachment: Access-scope attachment mapping (scope -> surface).
        modeled_resolvers: Valid resolver addresses from the modeled FS-540
            recursive DNS relationship.

    Returns:
        A CLAB requester fixture contract dict with requesterIdentity,
        requesterScope, accessAttachment, resolver, resolverSource,
        defaultRoute, and diagnostic identity.

    Raises:
        ValueError: With diagnostic identifier for missing requester, wrong
            attachment surface, or hardcoded/host-injected DNS behavior.
    """
    trace_id = "FS-540-HDS-020-SDS-010-SMS-010"

    # ── N1: Missing modeled requester fixture ──────────────────────────────
    if not requester_fixture or not isinstance(requester_fixture, dict):
        raise ValueError(
            f"{trace_id}: MISSING_CLAB_DNS_REQUESTER: "
            "required requester fixture data is absent"
        )

    scope = requester_fixture.get("requesterScope")
    if not isinstance(scope, str) or not scope:
        raise ValueError(
            f"{trace_id}: MISSING_CLAB_DNS_REQUESTER: "
            "requester fixture missing requesterScope"
        )

    # ── N2: Wrong attachment surface ───────────────────────────────────────
    attachment = (
        access_attachment
        if access_attachment is not None
        else requester_fixture.get("accessAttachment")
    )
    if not isinstance(attachment, dict):
        raise ValueError(
            f"{trace_id}: WRONG_ACCESS_ATTACHMENT: "
            f"no access attachment for requester scope '{scope}'"
        )

    surface = attachment.get("surface")
    surface_label = (
        f"'{surface}'" if isinstance(surface, str) else f"{surface!r}"
    )
    if surface not in _VALID_ACCESS_SURFACE_KINDS:
        raise ValueError(
            f"{trace_id}: WRONG_ACCESS_ATTACHMENT: "
            f"attachment surface {surface_label} is not an access surface "
            f"for requester scope '{scope}'; expected access surface kind"
        )

    # ── N3: Hardcoded or host-injected DNS behavior ────────────────────────
    resolver = requester_fixture.get("resolver")

    # Check for hardcoded public DNS address
    if isinstance(resolver, str) and resolver:
        if _is_public_hardcoded(resolver):
            raise ValueError(
                f"{trace_id}: HARDCODED_DNS_OR_ADDRESS: "
                f"resolver '{resolver}' is a hardcoded public DNS address "
                f"for requester scope '{scope}'; must be modeled FS-540 "
                f"recursive DNS relationship data"
            )

    # Check for host-side policy injection sources
    resolver_source = requester_fixture.get("resolverSource")
    if isinstance(resolver_source, str) and resolver_source:
        if resolver_source in _HOST_SIDE_SOURCES:
            raise ValueError(
                f"{trace_id}: HOST_SIDE_DNS_POLICY_INJECTION: "
                f"resolver source '{resolver_source}' for requester scope "
                f"'{scope}' indicates host-side DNS policy injection; "
                f"resolver and route data must come from the modeled "
                f"FS-540 relationship"
            )

    # Check for hardcoded resolver that isn't in modeled_resolvers
    if isinstance(resolver, str) and resolver and modeled_resolvers is not None:
        from ipaddress import ip_address

        try:
            parsed_ip = ip_address(resolver)
        except ValueError:
            # Not an IP address; could be a hostname — allow it but log
            parsed_ip = None

        if parsed_ip is not None:
            ip = str(parsed_ip)
            if ip not in modeled_resolvers:
                raise ValueError(
                    f"{trace_id}: HARDCODED_DNS_OR_ADDRESS: "
                    f"resolver '{resolver}' is not in modeled FS-540 "
                    f"resolver set for requester scope '{scope}'"
                )

    # ── Emit CLAB requester fixture contract ───────────────────────────────
    identity = requester_fixture.get(
        "requesterIdentity", f"dns-requester-{scope}"
    )
    return {
        "requesterIdentity": identity,
        "requesterScope": scope,
        "accessAttachment": attachment,
        "resolver": (
            str(resolver) if isinstance(resolver, str) and resolver else None
        ),
        "resolverSource": resolver_source,
        "defaultRoute": requester_fixture.get("defaultRoute"),
        "diagnostics": {
            "trace": trace_id,
            "sourceModule": "dns_requester_fixture",
        },
    }
