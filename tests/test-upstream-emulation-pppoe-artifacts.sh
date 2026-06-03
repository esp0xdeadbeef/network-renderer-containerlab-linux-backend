#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-integration-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

python3 - <<'PY'
from clabgen.models import SiteModel
from clabgen.s88.CM.lab_emulation import render_lab_emulation_artifacts

site = SiteModel(
    enterprise="esp",
    site="clab",
    nodes={},
    links={},
    single_access="",
    domains={},
    upstream_emulation={
        "pppoeClab": {
            "backend": "clab",
            "host": "s-router-clab",
            "mode": "pppoe",
            "handoff": {"bridge": "br-clab-pppoe", "mtu": 1492},
            "probeIntent": ["pppoe-session-up", "no-wan-dhcp", "no-wan-slaac"],
            "pppoe": {
                "server": {
                    "implementation": "accel-ppp",
                    "side": "provider",
                    "node": "sat-clab-pppoe-ac",
                    "handoffBridge": "br-clab-pppoe",
                    "session": {
                        "ipv4Prefix": "203.0.113.12/30",
                        "delegatedAggregate": "2001:db8:800:20::/60",
                    },
                },
                "client": {
                    "coreNode": "clab-router-core-simulated-isp",
                    "coreInterface": "pppoe-wan",
                    "runtimeInterface": "ppp0",
                    "handoffBridge": "br-clab-pppoe",
                    "addressDelivery": {
                        "ipv4": "pppoe-session-address",
                        "ipv6": "pppoe-delegated-prefix",
                        "wanDhcpFallback": False,
                        "wanSlaacFallback": False,
                    },
                },
            },
        }
    },
)

artifacts = render_lab_emulation_artifacts(site)
assert len(artifacts) == 1, artifacts
artifact = artifacts[0]
assert artifact["source"] == "control-plane-model"
assert artifact["providerEmulationMode"] == "pppoe"
assert artifact["backend"] == "clab"
assert artifact["handoff"]["bridge"] == "br-clab-pppoe"
assert artifact["server"]["implementation"] == "accel-ppp"
assert artifact["server"]["node"] == "sat-clab-pppoe-ac"
assert artifact["client"]["coreNode"] == "clab-router-core-simulated-isp"
assert artifact["client"]["runtimeInterface"] == "ppp0"
assert artifact["client"]["addressDelivery"]["wanDhcpFallback"] is False
assert artifact["client"]["addressDelivery"]["wanSlaacFallback"] is False
assert "pppoe-session-up" in artifact["probeIntent"]

bad_site = SiteModel(
    enterprise="esp",
    site="clab",
    nodes={},
    links={},
    single_access="",
    domains={},
    upstream_emulation={"bad": {"pppoe": {"server": {}}}},
)
try:
    render_lab_emulation_artifacts(bad_site)
except ValueError as exc:
    assert "requires explicit PPPoE server and client records" in str(exc)
else:
    raise AssertionError("missing PPPoE client did not fail closed")
PY

echo "PASS upstream-emulation-pppoe-artifacts"
