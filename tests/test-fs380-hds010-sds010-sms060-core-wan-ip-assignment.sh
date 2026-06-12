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
from clabgen.s88.CM.linux_wan_dynamic import render, _dhcp4_command, _slaac_command

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

# ── Predicate 1: DHCP command emitted for each WAN interface ──
print("=== Predicate 1: DHCP command emitted for each WAN interface ===")
cmds = []
for name in ["wan0", "wan1", "wan2"]:
    cmds.extend(render(make_node(name), eth_map))

# Each WAN interface should get a DHCP command
dhcp_cmds = [c for c in cmds if "udhcpc" in c]
check("Three DHCP commands emitted", len(dhcp_cmds) == 3)
for i, cmd in enumerate(dhcp_cmds):
    check(f"DHCP {i+1} targets correct interface", f"ens8{i}" in cmd)
    check(f"DHCP {i+1} has pid file", f"/run/udhcpc.ens8{i}.pid" in cmd)
    check(f"DHCP {i+1} runs in background", "-b" in cmd)

# ── Predicate 2: No hardcoded 10.11.0.x static IP commands ──
print("\n=== Predicate 2: No hardcoded 10.11.0.x static IP commands ===")
static_ip_cmds = [c for c in cmds if "ip addr replace 10.11.0." in c]
check("Zero static IP commands from 10.11.0.0/24", len(static_ip_cmds) == 0)
static_route_cmds = [c for c in cmds if "10.11.0.1" in c]
check("Zero references to 10.11.0.1 gateway", len(static_route_cmds) == 0)
static_snat_cmds = [c for c in cmds if "ip addr add 10.11.0." in c]
check("Zero SNAT IP commands", len(static_snat_cmds) == 0)

# ── Predicate 3: No hardcoded IP anywhere in output ──
print("\n=== Predicate 3: No hardcoded 10.11.0.x anywhere in output ===")
all_10_11 = [c for c in cmds if "10.11.0" in c]
check("Zero references to 10.11.0.x subnet anywhere", len(all_10_11) == 0)

# ── Predicate 4: SLAAC IPv6 commands still emitted ──
print("\n=== Predicate 4: SLAAC IPv6 commands emitted ===")
slaac_cmds = [c for c in cmds if "accept_ra=2" in c and "autoconf=1" in c]
check("Three SLAAC commands emitted", len(slaac_cmds) == 3)
for i, cmd in enumerate(slaac_cmds):
    check(f"SLAAC {i+1} targets correct interface", f"ens8{i}" in cmd)

# ── Predicate 5: DHCP command is idempotent (|| true) ──
print("\n=== Predicate 5: DHCP command is idempotent (|| true) ===")
for i, cmd in enumerate(dhcp_cmds):
    check(f"DHCP {i+1} has || true fallback", "|| true" in cmd)

# ── Predicate 6: Fail-closed — empty node produces no commands ──
print("\n=== Predicate 6: Fail-closed — empty node produces no commands ===")
empty_node = {"interfaces": {}}
cmds_empty = render(empty_node, eth_map)
check("Empty node produces no commands at all", len(cmds_empty) == 0)

# ── Predicate 7: Fail-closed — non-WAN interface produces no commands ──
print("\n=== Predicate 7: Fail-closed — non-WAN interface produces no commands ===")
non_wan_node = {
    "interfaces": {
        "lan0": {
            "kind": "lan",
            "hostUplink": {},
        }
    }
}
eth_map_lan = {"lan0": "eth1"}
cmds_non_wan = render(non_wan_node, eth_map_lan)
check("Non-WAN node produces no commands", len(cmds_non_wan) == 0)

# ── Predicate 8: NAT mode still uses _nat4_commands (CPM-derived) ──
print("\n=== Predicate 8: NAT mode uses CPM-derived addressing ===")
nat_node = {
    "interfaces": {
        "wan0": {
            "kind": "wan",
            "hostUplink": {
                "mode": "nat",
                "ipv4": {
                    "address": "192.168.1.1/24",
                    "clientAddress": "192.168.1.100",
                }
            },
        }
    }
}
eth_map_nat = {"wan0": "ens80"}
cmds_nat = render(nat_node, eth_map_nat)
check("NAT node emits commands", len(cmds_nat) > 0)
# Verify it uses the CPM-derived address, not 10.11.0.x
nat_ips = [c for c in cmds_nat if "ip addr replace" in c]
check("NAT mode emits ip addr replace", len(nat_ips) > 0)
for cmd in nat_ips:
    check("NAT mode uses CPM address (not 10.11.0.x)", "10.11.0." not in cmd)
    check("NAT mode uses CPM-derived 192.168.1.x", "192.168.1." in cmd)
# NAT mode should NOT use DHCP
nat_dhcp = [c for c in cmds_nat if "udhcpc" in c]
check("NAT mode does NOT emit DHCP", len(nat_dhcp) == 0)

# ── Predicate 9: Missing eth_map entry produces no commands ──
print("\n=== Predicate 9: Missing eth_map entry produces no commands ===")
orphan_node = {
    "interfaces": {
        "orphan_wan": {
            "kind": "wan",
            "hostUplink": {},
        }
    }
}
cmds_orphan = render(orphan_node, eth_map)
check("Orphan WAN (no eth_map) produces no commands", len(cmds_orphan) == 0)

print()
if failures:
    print(f"FAIL FS-380-HDS-010-SDS-010-SMS-060-CMC: {failures} failure(s)")
    sys.exit(1)
else:
    print("PASS FS-380-HDS-010-SDS-010-SMS-060-CMC")
PY
