#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_interfaces import _render_addressing
from clabgen.cpm_runtime import add_runtime_target
from clabgen.s88.site.model_builder import build_nodes

node = {
    "interfaces": {
        "testnet-routed": {
            "kind": "wan",
            "ipv4": {"address": "203.0.113.1/30"},
            "ipv6": {"address": "2001:db8:113::1/64"},
        },
        "testnet-host": {
            "kind": "wan",
            "ipv4": {"address": "203.0.113.5/32"},
            "ipv6": {"address": "2001:db8:113:64::1/64"},
        },
    }
}

commands = _render_addressing(
    node,
    {"testnet-routed": "ens4", "testnet-host": "ens5"},
)

assert "ip addr replace 203.0.113.1/30 dev ens4" in commands
assert "ip -6 addr replace 2001:db8:113::1/64 dev ens4" in commands
assert "ip addr replace 203.0.113.5/32 dev ens5" in commands
assert "ip -6 addr replace 2001:db8:113:64::1/64 dev ens5" in commands

runtime_target = {
    "role": "core",
    "routingDomain": "core",
    "routingMode": "static",
    "logicalNode": {"name": "provider"},
    "effectiveRuntimeRealization": {
        "interfaces": {
            "testnet-routed": {
                "kind": "wan",
                "runtimeIfName": "ens4",
                "ipv4": {"address": "203.0.113.1/30"},
                "ipv6": {"address": "2001:db8:113::1/64"},
            }
        }
    },
}

site = {"nodes": {}, "links": {}}
add_runtime_target(
    "provider-runtime",
    runtime_target,
    site["nodes"],
    site["links"],
    {},
    {},
    {},
)
model_node = build_nodes(site, {})["provider"]
model_iface = model_node.interfaces["testnet-routed"]
assert model_iface.addr4 == "203.0.113.1/30"
assert model_iface.addr6 == "2001:db8:113::1/64"
PY

echo "PASS provider-nested-wan-addressing"
