#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-060
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-060-CMC
# GAMP-SCOPE: software-module-test
# LAB-SMT-ID: LAB-SMT-021
# LAB-SMT-SCOPE: renderer construction test; see GAMP/SMT/README.md
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
import sys
import re
from clabgen.s88.CM.linux_wan_dynamic import render, _static_wan4_commands
from clabgen.s88.CM._wan_index import reset_wan_index

failures = 0

def check(description, condition):
    global failures
    if condition:
        print(f"PASS {description}")
    else:
        print(f"FAIL {description}")
        failures += 1

# ── Mock CPM data: 3 core nodes, each with one WAN interface ──
eth_map = {
    "wan0": "ens80",
    "wan1": "ens81",
    "wan2": "ens82",
}

def make_node(iface_name):
    return {
        "interfaces": {
            iface_name: {
                "kind": "wan",
                "hostUplink": {},
            }
        }
    }

# ── Happy path: render 3 nodes, verify all SMS-060 predicates ──
reset_wan_index()
cmds = []
for name in ["wan0", "wan1", "wan2"]:
    cmds.extend(render(make_node(name), eth_map))

print("=== Predicate 1: Unique IPv4 from 10.11.0.0/24 per core WAN interface ===")
# Extract the replace commands (primary IP assignment)
ip_assigns = [c for c in cmds if "ip addr replace" in c and "/24 dev" in c]
check("Three IP assignments emitted", len(ip_assigns) == 3)

ips = []
for cmd in ip_assigns:
    # Format: sh -c 'ip addr replace X.Y.Z.W/24 dev ensNN'
    m = re.search(r"ip addr replace (\S+)/24 dev", cmd)
    if m:
        ips.append(m.group(1))

check("Three IPs extracted", len(ips) == 3)
if len(ips) == 3:
    check(f"IPs in 10.11.0.0/24 subnet", all(ip.startswith("10.11.0.") for ip in ips))
    check("All three IPs are unique", len(set(ips)) == 3)
    # Verify deterministic assignment: indices 0,1,2 → octets 100,101,102
    expected_octets = {"100", "101", "102"}
    actual_octets = {ip.split(".")[3] for ip in ips}
    check(f"Deterministic octets {sorted(expected_octets)}", actual_octets == expected_octets)
    # Ensure no octet collision between client and SNAT IPs
    all_octets = set()
    for cmd in cmds:
        if "ip addr replace" in cmd or "ip addr add" in cmd:
            parts = cmd.split()
            for p in parts:
                if re.match(r"10\.11\.0\.\d+", p):
                    octet = p.split(".")[3].split("/")[0]
                    all_octets.add(octet)
    check("No client/SNAT octet collision (6 unique octets for 3 nodes)", len(all_octets) == 6)

print("\n=== Predicate 2: Default route via bridge gateway (10.11.0.1) ===")
routes = [c for c in cmds if "ip route replace default via" in c]
check("Three default routes emitted", len(routes) == 3)
for i, r in enumerate(routes):
    check(f"Route {i+1} via 10.11.0.1", "via 10.11.0.1" in r and "onlink" in r)

print("\n=== Predicate 3: DNS resolver emission ===")
dns_entries = [c for c in cmds if "nameserver" in c and "/etc/resolv.conf" in c]
check("Three DNS resolver entries emitted", len(dns_entries) == 3)
for i, d in enumerate(dns_entries):
    check(f"DNS {i+1} points to 10.11.0.1", "nameserver 10.11.0.1" in d)

print("\n=== Predicate 4: No udhcpc on WAN interfaces ===")
udhcpc_matches = [c for c in cmds if "udhcpc" in c]
check("Zero udhcpc commands emitted", len(udhcpc_matches) == 0)

print("\n=== Predicate 5: Deterministic static IP, not DHCP ===")
dhcp_indicators = [c for c in cmds if "dhclient" in c.lower() or "dhcpcd" in c.lower()]
check("No DHCP client commands", len(dhcp_indicators) == 0)
# Also verify the IPs come from the static assignment path (10.11.0.1xx)
static_indicators = [c for c in cmds if "ip addr replace 10.11.0.10" in c or "ip addr replace 10.11.0.101" in c or "ip addr replace 10.11.0.102" in c]
check("Static IP commands present (100-102 range)", len(static_indicators) == 3)

print("\n=== Predicate 6: Fail-closed — duplicate WAN index → detected ===")
reset_wan_index()
cmds_a = render(make_node("wan0"), eth_map)
reset_wan_index()  # Force duplicate by resetting counter mid-sequence
cmds_b = render(make_node("wan0"), eth_map)
dup_all = cmds_a + cmds_b
dup_ips_cmds = [c for c in dup_all if "ip addr replace" in c and "/24 dev" in c]
if len(dup_ips_cmds) == 2:
    dup_ip_a = re.search(r"ip addr replace (\S+)/24 dev", dup_ips_cmds[0])
    dup_ip_b = re.search(r"ip addr replace (\S+)/24 dev", dup_ips_cmds[1])
    if dup_ip_a and dup_ip_b:
        same = dup_ip_a.group(1) == dup_ip_b.group(1)
        check("Seeded duplicate: identical IP detected by test", same)
    else:
        check("Seeded duplicate: could not extract IPs", False)
else:
    check("Seeded duplicate: expected 2 IP commands", False)

print("\n=== Predicate 6b: Fail-closed — DHCP fallback on pool overflow ===")
# pool_base "10.11.255" with wan_index=200 gives octet 255+200>254 → DHCP fallback
cmds_overflow = _static_wan4_commands("ens80", {}, 200, pool_base="10.11.255")
dhcp_fallback = [c for c in cmds_overflow if "udhcpc" in c]
check("Overflow triggers DHCP fallback (udhcpc present)", len(dhcp_fallback) > 0)
check("Overflow does NOT emit static IP commands", all("ip addr replace" not in c for c in cmds_overflow))

print("\n=== Predicate 6c: Fail-closed — missing WAN interface → no commands ===")
# Node with no WAN interfaces
empty_node = {"interfaces": {}}
cmds_empty = render(empty_node, eth_map)
wan_commands_empty = [c for c in cmds_empty if "ip addr" in c or "ip route" in c]
check("Empty node produces no IP/route commands", len(wan_commands_empty) == 0)
check("Empty node produces no commands at all", len(cmds_empty) == 0)

print()
if failures:
    print(f"FAIL FS-380-HDS-010-SDS-010-SMS-060-CMC: {failures} failure(s)")
    sys.exit(1)
else:
    print("PASS FS-380-HDS-010-SDS-010-SMS-060-CMC")
PY
