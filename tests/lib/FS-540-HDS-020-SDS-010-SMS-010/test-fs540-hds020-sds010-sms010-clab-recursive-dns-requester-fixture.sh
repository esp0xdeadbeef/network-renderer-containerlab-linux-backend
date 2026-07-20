#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-020-SDS-010-SMS-010
# CLAB Recursive DNS Requester Fixture Construction Test
#
# Covers:
#   1. Positive case: valid requester fixture -> emits correct contract
#   2. Seeded negative 1: missing requester fixture -> MISSING_CLAB_DNS_REQUESTER
#   3. Seeded negative 2: wrong attachment surface -> WRONG_ACCESS_ATTACHMENT
#   4. Seeded negative 3a: hardcoded public DNS -> HARDCODED_DNS_OR_ADDRESS
#   5. Seeded negative 3b: host-side policy injection -> HOST_SIDE_DNS_POLICY_INJECTION
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import sys

from clabgen.s88.CM.dns_requester_fixture import render_dns_requester_fixture

TRACE = "FS-540-HDS-020-SDS-010-SMS-010"
FAILURES = 0


def fail(msg: str) -> None:
    global FAILURES
    FAILURES += 1
    print(f"FAIL: {msg}", file=sys.stderr)


def check_positive(name: str, fixture: dict, **kwargs) -> None:
    """Verify that valid input produces correct contract."""
    contract = render_dns_requester_fixture(fixture, **kwargs)
    errors = []
    if not isinstance(contract, dict):
        errors.append("contract is not a dict")
    if contract.get("requesterIdentity") != fixture.get(
        "requesterIdentity", f"dns-requester-{fixture['requesterScope']}"
    ):
        errors.append(
            f"wrong requesterIdentity: "
            f"{contract.get('requesterIdentity')}"
        )
    if contract.get("requesterScope") != fixture["requesterScope"]:
        errors.append(
            f"wrong requesterScope: {contract.get('requesterScope')}"
        )
    if contract.get("diagnostics", {}).get("trace") != TRACE:
        errors.append(
            f"missing/incorrect trace ID in diagnostics: "
            f"{contract.get('diagnostics', {}).get('trace')}"
        )
    if errors:
        for e in errors:
            fail(f"{name}: {e}")
    else:
        print(f"  POSITIVE PASS: {name}")


def check_negative(
    name: str,
    fixture: dict,
    expected_diag: str,
    **kwargs,
) -> None:
    """Verify that invalid input raises ValueError with correct diagnostic."""
    try:
        render_dns_requester_fixture(fixture, **kwargs)
        fail(
            f"{name}: ValueError not raised for '{expected_diag}'"
        )
    except ValueError as e:
        msg = str(e)
        if expected_diag not in msg:
            fail(
                f"{name}: missing diagnostic '{expected_diag}' "
                f"in: {msg}"
            )
        elif TRACE not in msg:
            fail(
                f"{name}: missing trace ID '{TRACE}' "
                f"in: {msg}"
            )
        else:
            print(f"  SEEDED NEGATIVE PASS: {name} -> {expected_diag}")
    except Exception as e:
        fail(
            f"{name}: wrong exception type "
            f"{type(e).__name__}: {e}"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# 1. POSITIVE CASE: valid requester fixture with tenant access surface
# ═══════════════════════════════════════════════════════════════════════════════

print("--- Positive cases ---")

valid_fixture = {
    "requesterScope": "tenant-media-client",
    "requesterIdentity": "dns-requester-tenant-media-client",
    "resolver": "10.20.0.53",
    "resolverSource": "modeled-fs540-recursive-dns",
    "defaultRoute": "10.20.0.1",
}

valid_attachment = {"surface": "tenant"}

check_positive(
    "valid-tenant-access",
    valid_fixture,
    access_attachment=valid_attachment,
)

# Also test with attachment from fixture directly
fixture_with_attachment = dict(valid_fixture)
fixture_with_attachment["accessAttachment"] = dict(valid_attachment)
check_positive(
    "valid-attachment-in-fixture",
    fixture_with_attachment,
)

# Test with IPv6 resolver
v6_fixture = {
    "requesterScope": "tenant-media-client",
    "resolver": "fd00:20::53",
    "resolverSource": "modeled-fs540-recursive-dns",
    "defaultRoute": "fd00:20::1",
}
check_positive(
    "valid-ipv6-resolver",
    v6_fixture,
    access_attachment=valid_attachment,
)

# Test without explicit identity — should generate from scope
no_id_fixture = {
    "requesterScope": "tenant-media-client",
    "resolver": "10.20.0.53",
    "resolverSource": "modeled-fs540-recursive-dns",
}
contract = render_dns_requester_fixture(
    no_id_fixture,
    access_attachment=valid_attachment,
)
assert (
    contract["requesterIdentity"] == "dns-requester-tenant-media-client"
), f"auto-generated identity wrong: {contract['requesterIdentity']}"
print("  POSITIVE PASS: auto-generated requesterIdentity")

# ═══════════════════════════════════════════════════════════════════════════════
# 2. SEEDED NEGATIVE N1: missing modeled requester fixture
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Seeded negative N1: missing requester fixture ---")

# N1a: empty dict
check_negative(
    "N1a-empty-fixture",
    {},
    "MISSING_CLAB_DNS_REQUESTER",
    access_attachment=valid_attachment,
)

# N1b: None
check_negative(
    "N1b-None-fixture",
    None,
    "MISSING_CLAB_DNS_REQUESTER",
    access_attachment=valid_attachment,
)

# N1c: non-dict
check_negative(
    "N1c-non-dict-fixture",
    "not-a-fixture",
    "MISSING_CLAB_DNS_REQUESTER",
    access_attachment=valid_attachment,
)

# N1d: missing requesterScope
check_negative(
    "N1d-missing-scope",
    {"resolver": "10.20.0.53"},
    "MISSING_CLAB_DNS_REQUESTER",
    access_attachment=valid_attachment,
)

# N1e: empty requesterScope
check_negative(
    "N1e-empty-scope",
    {"requesterScope": "", "resolver": "10.20.0.53"},
    "MISSING_CLAB_DNS_REQUESTER",
    access_attachment=valid_attachment,
)

# Recovery: add the required scope — should pass
recovery_fixture = {"requesterScope": "tenant-media-client", "resolver": "10.20.0.53", "resolverSource": "modeled-fs540-recursive-dns"}
check_positive(
    "N1-recovery",
    recovery_fixture,
    access_attachment=valid_attachment,
)

# ═══════════════════════════════════════════════════════════════════════════════
# 3. SEEDED NEGATIVE N2: wrong attachment surface
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Seeded negative N2: wrong attachment surface ---")

# N2a: management surface
mgmt_attachment = {"surface": "management"}
check_negative(
    "N2a-management-surface",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
    access_attachment=mgmt_attachment,
)

# N2b: provider surface
provider_attachment = {"surface": "provider"}
check_negative(
    "N2b-provider-surface",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
    access_attachment=provider_attachment,
)

# N2c: underlay surface
underlay_attachment = {"surface": "underlay"}
check_negative(
    "N2c-underlay-surface",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
    access_attachment=underlay_attachment,
)

# N2d: WAN surface
wan_attachment = {"surface": "wan"}
check_negative(
    "N2d-wan-surface",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
    access_attachment=wan_attachment,
)

# N2e: host-only surface
host_attachment = {"surface": "host-only"}
check_negative(
    "N2e-host-only-surface",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
    access_attachment=host_attachment,
)

# N2f: missing attachment entirely
check_negative(
    "N2f-no-attachment",
    valid_fixture,
    "WRONG_ACCESS_ATTACHMENT",
)

# N2g: None attachment
n2g_fixture = dict(valid_fixture)
n2g_fixture["accessAttachment"] = None
check_negative(
    "N2g-None-attachment",
    n2g_fixture,
    "WRONG_ACCESS_ATTACHMENT",
)

# Recovery: correct the attachment to tenant access — should pass
check_positive(
    "N2-recovery",
    valid_fixture,
    access_attachment={"surface": "tenant"},
)

# ═══════════════════════════════════════════════════════════════════════════════
# 4. SEEDED NEGATIVE N3a: hardcoded public DNS resolver
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Seeded negative N3a: hardcoded DNS resolver ---")

# N3a1: 8.8.8.8
hardcoded_8 = dict(valid_fixture)
hardcoded_8["resolver"] = "8.8.8.8"
check_negative(
    "N3a1-google-dns-8.8.8.8",
    hardcoded_8,
    "HARDCODED_DNS_OR_ADDRESS",
    access_attachment=valid_attachment,
)

# N3a2: 1.1.1.1
hardcoded_1 = dict(valid_fixture)
hardcoded_1["resolver"] = "1.1.1.1"
check_negative(
    "N3a2-cloudflare-dns-1.1.1.1",
    hardcoded_1,
    "HARDCODED_DNS_OR_ADDRESS",
    access_attachment=valid_attachment,
)

# N3a3: 9.9.9.9
hardcoded_9 = dict(valid_fixture)
hardcoded_9["resolver"] = "9.9.9.9"
check_negative(
    "N3a3-quad9-dns-9.9.9.9",
    hardcoded_9,
    "HARDCODED_DNS_OR_ADDRESS",
    access_attachment=valid_attachment,
)

# Recovery: use modeled resolver — should pass
check_positive(
    "N3a-recovery",
    valid_fixture,
    access_attachment=valid_attachment,
)

# ═══════════════════════════════════════════════════════════════════════════════
# 5. SEEDED NEGATIVE N3b: host-side DNS policy injection sources
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Seeded negative N3b: host-side DNS policy injection ---")

# N3b1: host-resolver source
host_resolver = dict(valid_fixture)
host_resolver["resolverSource"] = "host-resolver"
check_negative(
    "N3b1-host-resolver-source",
    host_resolver,
    "HOST_SIDE_DNS_POLICY_INJECTION",
    access_attachment=valid_attachment,
)

# N3b2: public-dns-default source
public_dns = dict(valid_fixture)
public_dns["resolverSource"] = "public-dns-default"
check_negative(
    "N3b2-public-dns-default-source",
    public_dns,
    "HOST_SIDE_DNS_POLICY_INJECTION",
    access_attachment=valid_attachment,
)

# N3b3: hardcoded source
hardcoded_src = dict(valid_fixture)
hardcoded_src["resolverSource"] = "hardcoded"
check_negative(
    "N3b3-hardcoded-source",
    hardcoded_src,
    "HOST_SIDE_DNS_POLICY_INJECTION",
    access_attachment=valid_attachment,
)

# N3b4: DHCP source
dhcp_src = dict(valid_fixture)
dhcp_src["resolverSource"] = "dhcp"
check_negative(
    "N3b4-dhcp-source",
    dhcp_src,
    "HOST_SIDE_DNS_POLICY_INJECTION",
    access_attachment=valid_attachment,
)

# Recovery: use modeled source — should pass
check_positive(
    "N3b-recovery",
    valid_fixture,
    access_attachment=valid_attachment,
)

# ═══════════════════════════════════════════════════════════════════════════════
# 6. MODELED RESOLVER WHITELIST CHECK
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Modeled resolver whitelist ---")

modeled = ["10.20.0.53", "10.20.0.54"]

# Valid: resolver in modeled list
check_positive(
    "modeled-resolver-match",
    valid_fixture,
    access_attachment=valid_attachment,
    modeled_resolvers=modeled,
)

# Invalid: resolver NOT in modeled list
not_modeled = dict(valid_fixture)
not_modeled["resolver"] = "10.99.99.99"
check_negative(
    "modeled-resolver-mismatch",
    not_modeled,
    "HARDCODED_DNS_OR_ADDRESS",
    access_attachment=valid_attachment,
    modeled_resolvers=modeled,
)

# ═══════════════════════════════════════════════════════════════════════════════
# 7. EMITTED CONTRACT FIELD COVERAGE
# ═══════════════════════════════════════════════════════════════════════════════

print("\n--- Emitted contract field coverage ---")

contract = render_dns_requester_fixture(
    valid_fixture,
    access_attachment=valid_attachment,
)

required_fields = [
    "requesterIdentity",
    "requesterScope",
    "accessAttachment",
    "resolver",
    "resolverSource",
    "defaultRoute",
    "diagnostics",
]
for field in required_fields:
    if field not in contract:
        fail(f"emitted contract missing field '{field}'")
    else:
        print(f"  FIELD COVERAGE: '{field}' present (value={contract[field]!r})")

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print()
if FAILURES:
    print(
        f"FAIL fs540-hds020-sds010-sms010-clab-recursive-dns-requester-fixture "
        f"({FAILURES} failure(s))"
    )
    sys.exit(1)

print(
    "PASS fs540-hds020-sds010-sms010-clab-recursive-dns-requester-fixture"
)
PY
