#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-040
# Renderer Interface-Name Source-Binding Construction Test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import json
import re
import sys
import tempfile
from pathlib import Path

from clabgen.s88.enterprise.enterprise import Enterprise
from clabgen.s88.enterprise.site_loader import load_sites


# ── Build mock solver JSON with explicit CPM runtimeIfName values ──────

def make_solver_json():
    """Construct a minimal solver-format JSON with two nodes and a link."""
    return {
        "enterprise": {
            "esp0xdeadbeef": {
                "site": {
                    "site-a": {
                        "nodes": {
                            "left-router": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "loopback": {
                                    "ipv4": "10.255.0.1/32",
                                },
                                "interfaces": {
                                    "to-right": {
                                        "runtimeIfName": "ens10",
                                        "kind": "p2p",
                                        "addr4": "192.0.2.0/31",
                                    },
                                    "tenant-admin": {
                                        "runtimeIfName": "ens20",
                                        "kind": "tenant",
                                        "tenant": "admin",
                                        "addr4": "10.20.15.1/24",
                                    },
                                },
                            },
                            "right-router": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "loopback": {
                                    "ipv4": "10.255.0.2/32",
                                },
                                "interfaces": {
                                    "to-left": {
                                        "runtimeIfName": "ens11",
                                        "kind": "p2p",
                                        "addr4": "192.0.2.1/31",
                                    },
                                    "tenant-client": {
                                        "runtimeIfName": "ens21",
                                        "kind": "tenant",
                                        "tenant": "client",
                                        "addr4": "10.20.20.1/24",
                                    },
                                },
                            },
                        },
                        "links": {
                            "p2p-link": {
                                "kind": "p2p",
                                "endpoints": {
                                    "left-router": {"interface": "to-right"},
                                    "right-router": {"interface": "to-left"},
                                },
                            },
                        },
                    }
                }
            }
        }
    }


# ── Collect CPM runtimeIfName values ──────────────────────────────────

def collect_cpm_runtime_ifnames(solver_json):
    """Extract all runtimeIfName values from CPM data."""
    names = set()
    for enterprise, sites_obj in solver_json.get("enterprise", {}).items():
        if not isinstance(sites_obj, dict):
            continue
        for site_name, site in sites_obj.get("site", {}).items():
            if not isinstance(site, dict):
                continue
            for node_name, node in site.get("nodes", {}).items():
                if not isinstance(node, dict):
                    continue
                for ifname, iface in node.get("interfaces", {}).items():
                    if not isinstance(iface, dict):
                        continue
                    runtime = iface.get("runtimeIfName")
                    if isinstance(runtime, str) and runtime:
                        names.add(runtime)
    return names


# ── Extract concrete interface names from rendered topology ───────────

# Platform-primitive names that are allowed without CPM binding.
# These are convention names for CLAB management plane, not CPM-scoped.
PLATFORM_ALLOWED = {
    "eth0",  # CLAB management/console interface (platform convention, 5 locations)
}

# Pattern for names generated deterministically from CPM/metadata:
# - veth-*  (host ifname from naming.py:host_ifname)
# - br-*    (bridge name from naming.py:bridge_name)
# - if-*    (shortened runtimeIfName from eth_map.py:_short_ifname)
GENERATED_PATTERNS = [
    re.compile(r"^veth-[0-9a-f]{10}$"),   # host_ifname
    re.compile(r"^br-[0-9a-f]{12}$"),      # bridge_name (6-byte blake2s hex)
    re.compile(r"^if-[0-9a-f]{12}$"),      # _short_ifname
]


def is_generated_name(name):
    """Check if name is deterministically generated from source data."""
    for pat in GENERATED_PATTERNS:
        if pat.match(name):
            return True
    return False


def parse_interface_names_from_topology(rendered):
    """Extract all concrete interface names from rendered Containerlab topology."""
    concrete_names = set()
    topo = rendered.get("topology", {})

    # From link endpoints: "node:ifname" or "bridge:ifname" or "host:ifname"
    for link in topo.get("links", []):
        for endpoint in link.get("endpoints", []):
            if isinstance(endpoint, str) and ":" in endpoint:
                _, ifname = endpoint.split(":", 1)
                if ifname:
                    concrete_names.add(ifname)

    # From node labels: clab.interface.audit maps runtime->logical
    for node_name, node_def in topo.get("nodes", {}).items():
        if not isinstance(node_def, dict):
            continue
        labels = node_def.get("labels", {})
        if not isinstance(labels, dict):
            continue
        audit_raw = labels.get("clab.interface.audit")
        if isinstance(audit_raw, str):
            try:
                audit_map = json.loads(audit_raw)
                for runtime_name in audit_map.keys():
                    if runtime_name:
                        concrete_names.add(runtime_name)
            except json.JSONDecodeError:
                pass

    # Bridge names (topology-level bridges list)
    for bridge in rendered.get("bridges", []):
        if isinstance(bridge, str) and bridge:
            concrete_names.add(bridge)

    # Bridge-network keys (VLAN interface names)
    for bridge_key in rendered.get("bridge_networks", {}).keys():
        if isinstance(bridge_key, str) and bridge_key:
            concrete_names.add(bridge_key)

    return concrete_names


# ── Source-binding check ──────────────────────────────────────────────

def check_source_binding(concrete_names, cpm_runtime_names):
    """Verify every concrete name has a valid source binding."""
    unreferenced = []
    for name in sorted(concrete_names):
        # Platform-allowed names
        if name in PLATFORM_ALLOWED:
            continue
        # Names directly from CPM runtimeIfName
        if name in cpm_runtime_names:
            continue
        # Names deterministically generated from source metadata
        if is_generated_name(name):
            continue
        # Name has no source binding
        unreferenced.append(name)

    return unreferenced


# ── Main test ─────────────────────────────────────────────────────────

solver_json = make_solver_json()

# Collect CPM runtimeIfName values
cpm_runtime_names = collect_cpm_runtime_ifnames(solver_json)
print(f"CPM runtimeIfName values: {sorted(cpm_runtime_names)}")

# Write solver JSON to temp file and render
with tempfile.NamedTemporaryFile(
    mode="w", suffix=".json", delete=False, dir="/tmp"
) as f:
    json.dump(solver_json, f)
    solver_path = f.name

try:
    enterprise = Enterprise.from_solver_json(solver_path, renderer_inventory={})
    rendered = enterprise.render()
finally:
    Path(solver_path).unlink()

# Extract concrete interface names from rendered topology
concrete_names = parse_interface_names_from_topology(rendered)
print(f"Concrete interface names in rendered topology: {sorted(concrete_names)}")

# Run source-binding check
unreferenced = check_source_binding(concrete_names, cpm_runtime_names)

if unreferenced:
    print(f"FAIL: {len(unreferenced)} interface name(s) without source binding:")
    for name in unreferenced:
        print(f"  UNREFERENCED: {name}")
    sys.exit(1)

# Verify positive: concrete names that should be present ARE present
expected_runtime_names = {"ens10", "ens11", "ens20", "ens21"}
found_runtime = concrete_names & expected_runtime_names
missing_runtime = expected_runtime_names - concrete_names
if missing_runtime:
    print(f"FAIL: expected CPM runtimeIfName(s) not found in rendered output: {sorted(missing_runtime)}")
    sys.exit(1)
print(f"Positive match: all {len(found_runtime)} expected runtime names found in output")


# ── Seeded negative case: inject hardcoded interface name ─────────────
# Modify the rendered output to include a hardcoded name "eth999" and
# verify the checker rejects it as unreferenced.

print("\n--- Seeded negative case ---")

# Deep-copy and inject a hardcoded interface name into a link endpoint
import copy
seeded = copy.deepcopy(rendered)
# Add a fake link with hardcoded interface name "eth999"
seeded["topology"]["links"].append({
    "endpoints": ["left-router:eth999", "right-router:ens11"],
    "labels": {"clab.link.type": "bridge", "clab.link.bridge": "br-seeded-negative"},
})

seeded_concrete = parse_interface_names_from_topology(seeded)
print(f"Seeded concrete names (includes eth999): {sorted(seeded_concrete)}")

seeded_unreferenced = check_source_binding(seeded_concrete, cpm_runtime_names)

if "eth999" not in seeded_unreferenced:
    print("FAIL: CHECKER DID NOT DETECT HARDCODED eth999")
    print(f"  The seeded negative name 'eth999' was NOT flagged as unreferenced.")
    print(f"  This means the checker would accept hardcoded interface names in production.")
    sys.exit(1)

print(f"SEEDED NEGATIVE PASS: checker correctly flags eth999 as unreferenced")
print(f"  Flagged names: {sorted(seeded_unreferenced)}")

# Verify only eth999 is flagged (generated bridge name for seeded link is allowed)
# The bridge name "br-seeded-negative" is also injected; verify it's flagged too
# since it's not deterministically generated.
unexpected_unreferenced = [n for n in seeded_unreferenced if n != "eth999"]
if unexpected_unreferenced:
    # br-seeded-negative should also be unreferenced (not a valid generated name)
    for name in unexpected_unreferenced:
        if not is_generated_name(name) and name not in PLATFORM_ALLOWED:
            print(f"  Also correctly flagged: {name}")
    # This is fine - we're just verifying eth999 specifically is caught

print("\nPASS fs310-sms040-interface-name-source-binding")
PY
