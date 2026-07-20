#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-110-CMC-CLAB-FAIL-CLOSED-DOMAIN
# Construction test for CLAB renderer fail-closed HIGH findings:
#   CL-HIGH-1: domain must not default to "lan."
#   CL-HIGH-2: enabled must default to False (opt-in only)
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.access_advertisements import (
    _enabled,
    _dhcp4_config,
)

# ─── CL-HIGH-2: enabled defaults to False (fail-closed, opt-in) ───

# Missing 'enabled' key → defaults to False → not enabled
assert _enabled({}) is False, "CL-HIGH-2 FAIL: enabled should default to False"
assert _enabled({"enabled": False}) is False, "CL-HIGH-2 FAIL: explicit False should be not enabled"
assert _enabled({"enabled": True}) is True, "CL-HIGH-2 FAIL: explicit True should be enabled"

# None / non-boolean values should not bypass
assert _enabled({"enabled": None}) is False, "CL-HIGH-2 FAIL: None should be not enabled"

# ─── CL-HIGH-1: domain must not default to "lan." ───

# Full valid input (must succeed)
valid_scope = {
    "subnet": "10.50.20.0/24",
    "pool": {"start": "10.50.20.100", "end": "10.50.20.200"},
    "routerAddress": "10.50.20.1",
    "dnsServers": ["10.50.20.1"],
    "domain": "example.local",
}
config = _dhcp4_config(valid_scope, "eth2")
assert "option domain example.local" in config, \
    "CL-HIGH-1 FAIL: valid domain should be in output"
assert "option dns 10.50.20.1" in config, \
    "CL-HIGH-3 FAIL: dnsServers should be in output"

# Missing domain → must raise ValueError (fail-closed)
try:
    missing_domain = dict(valid_scope)
    del missing_domain["domain"]
    _dhcp4_config(missing_domain, "eth2")
    raise AssertionError("CL-HIGH-1 FAIL: missing domain should raise ValueError")
except ValueError as exc:
    assert "domain" in str(exc), \
        f"CL-HIGH-1 FAIL: ValueError should mention 'domain', got: {exc}"

# Empty domain → must raise ValueError
try:
    empty_domain = dict(valid_scope)
    empty_domain["domain"] = ""
    _dhcp4_config(empty_domain, "eth2")
    raise AssertionError("CL-HIGH-1 FAIL: empty domain should raise ValueError")
except ValueError as exc:
    assert "domain" in str(exc), \
        f"CL-HIGH-1 FAIL: ValueError should mention 'domain', got: {exc}"

# ─── CL-HIGH-3: dnsServers must not fall back to router ───

# Missing dnsServers → must raise ValueError
try:
    missing_dns = dict(valid_scope)
    missing_dns["domain"] = "example.local"  # keep domain valid
    del missing_dns["dnsServers"]
    _dhcp4_config(missing_dns, "eth2")
    raise AssertionError("CL-HIGH-3 FAIL: missing dnsServers should raise ValueError")
except ValueError as exc:
    assert "dnsServers" in str(exc), \
        f"CL-HIGH-3 FAIL: ValueError should mention 'dnsServers', got: {exc}"

# Empty dnsServers list → must raise ValueError
try:
    empty_dns = dict(valid_scope)
    empty_dns["domain"] = "example.local"
    empty_dns["dnsServers"] = []
    _dhcp4_config(empty_dns, "eth2")
    raise AssertionError("CL-HIGH-3 FAIL: empty dnsServers should raise ValueError")
except ValueError as exc:
    assert "dnsServers" in str(exc), \
        f"CL-HIGH-3 FAIL: ValueError should mention 'dnsServers', got: {exc}"

print("PASS FS-310-HDS-010-SDS-010-SMS-110-CMC-CLAB-FAIL-CLOSED-DOMAIN")
PY
