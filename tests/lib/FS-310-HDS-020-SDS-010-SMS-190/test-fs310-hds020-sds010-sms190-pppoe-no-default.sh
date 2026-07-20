#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-190
# Renderer PPPoE No-Default Contract Construction Test
#
# Proves: PPPoE renderer fails closed on missing CPM fields (mtu, maxSessions,
# runtimeInterface, defaultRoute, usePeerDns) rather than supplying hardcoded
# defaults. Commit 4db3beb removed all `or` fallbacks; this test exercises
# the fail-closed paths.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

python3 - <<'PY'
import sys
from clabgen.s88.CM.pppoe_runtime import (
    _client_command, _server_command, _bool_option, _dict, _string, _interface,
)

# ── Helpers ──────────────────────────────────────────────────────────
FIELDS_CLIENT = {"mtu", "runtimeInterface", "defaultRoute", "usePeerDns",
                 "interface", "credentials"}
FIELDS_SERVER = {"mtu", "maxSessions", "interface", "providerAddress",
                 "customerAddress", "credentials"}

def make_client_config(**overrides):
    """Valid client config with all required CPM fields."""
    cfg = {
        "interface": "pppoe-client-iface",
        "runtimeInterface": "ppp1",
        "mtu": 1492,
        "defaultRoute": True,
        "usePeerDns": False,
        "credentials": {"username": "testuser", "password": "testpass"},
    }
    cfg.update(overrides)
    return cfg

def make_server_config(**overrides):
    """Valid server config with all required CPM fields."""
    cfg = {
        "interface": "pppoe-server-iface",
        "mtu": 1492,
        "maxSessions": 32,
        "providerAddress": "203.0.113.5",
        "customerAddress": "203.0.113.4",
        "credentials": {"username": "testuser", "password": "testpass"},
    }
    cfg.update(overrides)
    return cfg

# Minimal eth_map
eth_map = {"pppoe-client-iface": "ens8", "pppoe-server-iface": "ens9"}

# ── Happy path: valid configs produce commands ───────────────────────
print("=== Happy Path ===")
client_cmd = _client_command(make_client_config(), eth_map)
assert "pppd" in client_cmd, "client command missing pppd"
assert "pppoe" in client_cmd, "client command missing pppoe"
assert "mtu 1492" in client_cmd, "client command missing mtu"
assert "ifname ppp1" in client_cmd, "client command missing ifname"
assert "defaultroute replacedefaultroute" in client_cmd, "defaultRoute=True not emitted"
print("  PASS: client happy path")

server_cmd = _server_command(make_server_config(), eth_map)
assert "pppoe-server" in server_cmd, "server command missing pppoe-server"
assert "mtu 1492" in server_cmd, "server command missing mtu"
assert "-N 32" in server_cmd, "server command missing maxSessions"
print("  PASS: server happy path")

# _bool_option tests
assert _bool_option({"defaultRoute": True}, "defaultRoute") == True, "True→True"
assert _bool_option({"defaultRoute": False}, "defaultRoute") == False, "False→False"
print("  PASS: _bool_option explicit")

# ── Seeded Negatives: missing CPM fields → ValueError ────────────────
print("\n=== Seeded Negatives (missing CPM fields) ===")
failures_expected = 0
failures_caught = 0

# Client: missing mtu
failures_expected += 1
try:
    _client_command(make_client_config(mtu=None), eth_map)
    print("  FAIL: missing mtu did not raise")
except ValueError as e:
    assert "mtu" in str(e).lower(), f"wrong error for missing mtu: {e}"
    print(f"  PASS: missing mtu → ValueError: {e}")
    failures_caught += 1

# Client: missing runtimeInterface
failures_expected += 1
try:
    _client_command(make_client_config(runtimeInterface=None), eth_map)
    print("  FAIL: missing runtimeInterface did not raise")
except ValueError as e:
    assert "runtimeinterface" in str(e).lower(), f"wrong error for missing runtimeInterface: {e}"
    print(f"  PASS: missing runtimeInterface → ValueError: {e}")
    failures_caught += 1

# Client: missing defaultRoute
failures_expected += 1
try:
    cfg = make_client_config()
    del cfg["defaultRoute"]
    _client_command(cfg, eth_map)
    print("  FAIL: missing defaultRoute did not raise")
except ValueError as e:
    assert "defaultroute" in str(e).lower(), f"wrong error for missing defaultRoute: {e}"
    print(f"  PASS: missing defaultRoute → ValueError: {e}")
    failures_caught += 1

# Client: missing usePeerDns
failures_expected += 1
try:
    cfg = make_client_config()
    del cfg["usePeerDns"]
    _client_command(cfg, eth_map)
    print("  FAIL: missing usePeerDns did not raise")
except ValueError as e:
    assert "usepeerdns" in str(e).lower(), f"wrong error for missing usePeerDns: {e}"
    print(f"  PASS: missing usePeerDns → ValueError: {e}")
    failures_caught += 1

# Server: missing mtu
failures_expected += 1
try:
    _server_command(make_server_config(mtu=None), eth_map)
    print("  FAIL: server missing mtu did not raise")
except ValueError as e:
    assert "mtu" in str(e).lower(), f"wrong error for server missing mtu: {e}"
    print(f"  PASS: server missing mtu → ValueError: {e}")
    failures_caught += 1

# Server: missing maxSessions
failures_expected += 1
try:
    _server_command(make_server_config(maxSessions=None), eth_map)
    print("  FAIL: server missing maxSessions did not raise")
except ValueError as e:
    assert "maxsessions" in str(e).lower(), f"wrong error for server missing maxSessions: {e}"
    print(f"  PASS: server missing maxSessions → ValueError: {e}")
    failures_caught += 1

assert failures_caught == failures_expected, \
    f"Expected {failures_expected} failures, caught {failures_caught}"

# ── Source scan: no `or <hardcoded>` fallbacks remain ────────────────
print("\n=== Source Scan: no `or` fallbacks ===")
import subprocess
result = subprocess.run(
    ["grep", "-n", r'or 1492\|or 32\|or "ppp0"\|_bool_option.*, True)',
     "clabgen/s88/CM/pppoe_runtime.py"],
    capture_output=True, text=True
)
# The old hardcoded patterns are gone; grep should find nothing
# (exit 1 means no matches, which is PASS in this context)
if result.returncode == 1:
    print("  PASS: no hardcoded `or 1492`, `or 32`, `or \"ppp0\"` found")
elif result.returncode == 0:
    print(f"  FAIL: hardcoded fallbacks still present:\n{result.stdout}")
    sys.exit(1)

print(f"\nPASS FS-310-HDS-020-SDS-010-SMS-190: {failures_caught}/{failures_expected} seeded negatives caught, no source fallbacks")
PY
