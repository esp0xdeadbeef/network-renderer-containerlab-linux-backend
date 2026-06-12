#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-050-CMC-001-CLAB
# SMS-050: Renderer internet mode verification — CLAB module-level (mock CPM)
# Verifies that clabgen/s88/CM/nat.py generates correct masquerade rules.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

echo "=== Test CLAB NAT generates masquerade ==="

# Run nat.py render with mock input including translationRecords
result="$(python3 -c '
import sys
sys.path.insert(0, ".")
from clabgen.s88.CM.nat import render

input_data = {
    "ipv4": True,
    "ipv6": False,
    "masqueradeInterfaces": ["eth2"],
    "routes_v4": [],
    "routes_v6": [],
}
cmds = render(input_data)
for cmd in cmds:
    print(cmd)
')"

# Verify masquerade rule exists on the correct interface
if ! echo "$result" | grep -q 'nft add rule ip nat postrouting oifname "eth2" masquerade'; then
  echo "FAIL: CLAB NAT missing masquerade rule on eth2"
  echo "$result"
  exit 1
fi
echo "PASS: CLAB NAT generates masquerade on WAN interface"

# Verify no hardcoded eth0
if echo "$result" | grep -q 'oifname "eth0"'; then
  echo "FAIL: CLAB NAT still contains hardcoded eth0"
  echo "$result"
  exit 1
fi
echo "PASS: CLAB NAT no longer hardcodes eth0"

# Verify ip_forward sysctl
if ! echo "$result" | grep -q 'sysctl -w net.ipv4.ip_forward=1'; then
  echo "FAIL: CLAB NAT missing IPv4 forwarding"
  exit 1
fi
echo "PASS: CLAB NAT enables IPv4 forwarding"

# Verify IPv6 forwarding
if ! echo "$result" | grep -q 'sysctl -w net.ipv6.conf.all.forwarding=1'; then
  echo "FAIL: CLAB NAT missing IPv6 forwarding"
  exit 1
fi
echo "PASS: CLAB NAT enables IPv6 forwarding"

# Verify no nat table when ipv4 disabled
echo "=== Test CLAB NAT respects disabled families ==="
disabled_result="$(python3 -c '
import sys
sys.path.insert(0, ".")
from clabgen.s88.CM.nat import render

input_data = {
    "ipv4": False,
    "ipv6": False,
    "masqueradeInterfaces": [],
    "routes_v4": [],
    "routes_v6": [],
}
for cmd in render(input_data):
    print(cmd)
')"

if echo "$disabled_result" | grep -q 'nft add table'; then
  echo "FAIL: CLAB NAT emitted table rules with NAT disabled"
  echo "$disabled_result"
  exit 1
fi
echo "PASS: CLAB NAT skips table creation when NAT disabled"

# Test with routes
echo "=== Test CLAB NAT with routes ==="
route_result="$(python3 -c '
import sys
sys.path.insert(0, ".")
from clabgen.s88.CM.nat import render

input_data = {
    "ipv4": True,
    "ipv6": True,
    "masqueradeInterfaces": ["eth2"],
    "routes_v4": [{"dst": "10.50.0.0/16", "via4": "10.50.44.35"}],
    "routes_v6": [{"dst": "fd42:dead:feed::/48", "via6": "fd42:dead:feed:1000::1"}],
}
for cmd in render(input_data):
    print(cmd)
')"

if ! echo "$route_result" | grep -q 'ip route replace 10.50.0.0/16 via 10.50.44.35'; then
  echo "FAIL: CLAB NAT missing IPv4 fabric route"
  exit 1
fi
echo "PASS: CLAB NAT adds IPv4 fabric route"

if ! echo "$route_result" | grep -q 'ip -6 route replace fd42:dead:feed::/48 via fd42:dead:feed:1000::1'; then
  echo "FAIL: CLAB NAT missing IPv6 fabric route"
  exit 1
fi
echo "PASS: CLAB NAT adds IPv6 fabric route"

echo ""
echo "ALL SMS-050 CLAB CMC TESTS PASSED"
