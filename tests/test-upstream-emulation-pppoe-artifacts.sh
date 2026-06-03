#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-integration-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

python3 - <<'PY'
from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.CM.lab_emulation import render_lab_emulation_artifacts
from clabgen.s88.site.topology import render_site_topology

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

runtime_site = SiteModel(
    enterprise="esp",
    site="clab",
    nodes={
        "clab-router-core-simulated-isp": NodeModel(
            name="clab-router-core-simulated-isp",
            role="core",
            routing_domain="core",
            routing_mode="static",
            interfaces={
                "pppoe-wan": InterfaceModel(
                    name="pppoe-wan",
                    runtime_if_name="eth1",
                    kind="wan",
                )
            },
        )
    },
    links={
        "pppoe-handoff": LinkModel(
            name="pppoe-handoff",
            kind="lan",
            bridge="br-clab-pppoe",
            endpoints={
                "clab-router-core-simulated-isp": {"interface": "pppoe-wan"}
            },
        )
    },
    single_access="",
    domains={},
    upstream_emulation=site.upstream_emulation,
)
topology = render_site_topology(runtime_site)
nodes = topology["topology"]["nodes"]
core_exec = "\n".join(nodes["clab-router-core-simulated-isp"]["exec"])
server_exec = "\n".join(nodes["sat-clab-pppoe-ac"]["exec"])
assert "pppd pty" in core_exec and "pppoe -I eth1" in core_exec
assert "udhcpc -b -i eth1" not in core_exec
assert "accept_ra=2" not in core_exec
assert "pppoe-server -I eth1" in server_exec
assert any("sat-clab-pppoe-ac:eth1" in link["endpoints"] for link in topology["topology"]["links"])
PY

rg -q 'ppp' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
rg -q 'rp-pppoe' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"

echo "PASS upstream-emulation-pppoe-artifacts"
