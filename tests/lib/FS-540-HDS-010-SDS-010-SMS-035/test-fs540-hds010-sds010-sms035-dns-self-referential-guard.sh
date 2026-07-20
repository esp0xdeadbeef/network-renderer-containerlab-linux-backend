#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-035
# CLAB DNS Self-Referential Forwarder Guard Construction Test
#
# Covers:
#   1. Positive case: DNS config with correct forwarders (different from listen) -> no error
#   2. Seeded negative: forwarder that matches a listen address -> ValueError raised
#   3. Both IPv4 and IPv6 self-referential cases
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import sys

from clabgen.s88.CM.dns_service import render_dns_service


# ═══════════════════════════════════════════════════════════════════════════════
# 1. POSITIVE CASE: correct forwarders (no self-reference)
# ═══════════════════════════════════════════════════════════════════════════════

dns_ok = {
    "listen": ["10.20.0.1", "fd00:20::1"],
    "forwarders": ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"],
}

try:
    result = render_dns_service({"services": {"dns": dns_ok}})
    print("POSITIVE PASS: render_dns_service completed without error")
    print(f"  Rendered {len(result)} command(s)")
    # Verify the rendered output contains the config payload
    rendered = "\n".join(result)
    assert '"forwarders"' in rendered, "rendered output missing forwarders"
    assert '"1.1.1.1"' in rendered, "rendered output missing expected forwarder"
    print("  Rendered output contains forwarders config")
except Exception as e:
    print(f"POSITIVE FAIL: unexpected error: {e}")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════════
# 2. SEEDED NEGATIVE: IPv4 forwarder matches listen address
# ═══════════════════════════════════════════════════════════════════════════════

dns_self_ref_v4 = {
    "listen": ["10.20.0.1", "10.30.0.1"],
    "forwarders": ["1.1.1.1", "10.20.0.1", "8.8.8.8"],
}

try:
    render_dns_service({"services": {"dns": dns_self_ref_v4}}, node_name="test-v4-container")
    print("SEEDED NEGATIVE (v4) FAIL: ValueError was not raised for self-referential forwarder")
    sys.exit(1)
except ValueError as e:
    msg = str(e)
    if "FS-540-HDS-010-SDS-010-SMS-035" not in msg:
        print(f"SEEDED NEGATIVE (v4) FAIL: missing GAMP trace ID in error message")
        print(f"  Got: {msg}")
        sys.exit(1)
    if "DNS_RENDERER_CONTRACT_DIVERGENCE" not in msg:
        print("SEEDED NEGATIVE (v4) FAIL: missing stable warning code")
        sys.exit(1)
    if "10.20.0.1" in msg or "test-v4-container" in msg:
        print("SEEDED NEGATIVE (v4) FAIL: diagnostic leaked address or runtime identity")
        sys.exit(1)
    print("SEEDED NEGATIVE (v4) PASS: redacted ValueError raised correctly")
except Exception as e:
    print(f"SEEDED NEGATIVE (v4) FAIL: wrong exception type: {type(e).__name__}: {e}")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════════
# 3. SEEDED NEGATIVE: IPv6 forwarder matches listen address
# ═══════════════════════════════════════════════════════════════════════════════

dns_self_ref_v6 = {
    "listen": ["fd00:20::1", "fd00:30::1"],
    "forwarders": ["2606:4700:4700::1111", "fd00:20::1"],
}

try:
    render_dns_service({"services": {"dns": dns_self_ref_v6}}, node_name="test-v6-container")
    print("SEEDED NEGATIVE (v6) FAIL: ValueError was not raised for self-referential forwarder (IPv6)")
    sys.exit(1)
except ValueError as e:
    msg = str(e)
    if "FS-540-HDS-010-SDS-010-SMS-035" not in msg:
        print(f"SEEDED NEGATIVE (v6) FAIL: missing GAMP trace ID in error message")
        print(f"  Got: {msg}")
        sys.exit(1)
    if "DNS_RENDERER_CONTRACT_DIVERGENCE" not in msg:
        print("SEEDED NEGATIVE (v6) FAIL: missing stable warning code")
        sys.exit(1)
    if "fd00:20::1" in msg or "test-v6-container" in msg:
        print("SEEDED NEGATIVE (v6) FAIL: diagnostic leaked address or runtime identity")
        sys.exit(1)
    print("SEEDED NEGATIVE (v6) PASS: redacted ValueError raised correctly")
except Exception as e:
    print(f"SEEDED NEGATIVE (v6) FAIL: wrong exception type: {type(e).__name__}: {e}")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════════
# 4. SEEDED NEGATIVE: loopback addresses as forwarders should NOT trigger guard
#    (forwarders are checked against non-loopback only)
# ═══════════════════════════════════════════════════════════════════════════════

dns_loopback_fwd = {
    "listen": ["10.20.0.1"],
    "forwarders": ["127.0.0.1", "::1"],
}

try:
    result = render_dns_service({"services": {"dns": dns_loopback_fwd}})
    print("LOOPBACK FORWARDER PASS: loopback addresses as forwarders do NOT trigger guard")
except ValueError as e:
    print(f"LOOPBACK FORWARDER FAIL: loopback forwarder incorrectly triggered guard: {e}")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════════
# 5. SEEDED NEGATIVE: multiple self-referential forwarders
# ═══════════════════════════════════════════════════════════════════════════════

dns_multi_self_ref = {
    "listen": ["10.20.0.1", "10.30.0.1"],
    "forwarders": ["10.20.0.1", "10.30.0.1", "1.1.1.1"],
}

try:
    render_dns_service({"services": {"dns": dns_multi_self_ref}}, node_name="multi-test")
    print("MULTI SELF-REF FAIL: ValueError was not raised for multiple self-referential forwarders")
    sys.exit(1)
except ValueError as e:
    msg = str(e)
    if "DNS_RENDERER_CONTRACT_DIVERGENCE" not in msg:
        print("MULTI SELF-REF FAIL: missing stable warning code")
        sys.exit(1)
    if "10.20.0.1" in msg or "10.30.0.1" in msg or "multi-test" in msg:
        print("MULTI SELF-REF FAIL: diagnostic leaked address or runtime identity")
        sys.exit(1)
    print("MULTI SELF-REF PASS: redacted aggregate diagnostic reported")
except Exception as e:
    print(f"MULTI SELF-REF FAIL: wrong exception type: {type(e).__name__}: {e}")
    sys.exit(1)


print("\nPASS fs540-hds010-sds010-sms035-dns-self-referential-guard")
PY
