#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-020-SMS-010
# GAMP-SCOPE: software-integration-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

python3 - <<'PY'
import json
import tempfile
from pathlib import Path

from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.CM.lab_emulation import render_lab_emulation_artifacts
from clabgen.s88.CM.linux_wan_dynamic import render as render_dynamic_wan
from clabgen.s88.CM.pppoe_runtime import render as render_pppoe_runtime
from clabgen.s88.enterprise.site_loader import load_sites
from clabgen.s88.site.topology import render_site_topology

side_channel_payload = {
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
            },
            "client": {
                "coreNode": "clab-router-core-simulated-isp",
                "coreInterface": "pppoe-wan",
                "runtimeInterface": "ppp0",
                "handoffBridge": "br-clab-pppoe",
            },
        },
    }
}


def assert_load_rejects(field_name):
    with tempfile.TemporaryDirectory() as tmpdir:
        cpm = {
            "enterprise": {
                "esp": {
                    "site": {
                        "clab": {
                            "nodes": {},
                            "links": {},
                            field_name: side_channel_payload,
                        }
                    }
                }
            }
        }
        path = Path(tmpdir) / f"{field_name}.json"
        path.write_text(json.dumps(cpm))
        try:
            load_sites(path)
        except ValueError as exc:
            message = str(exc)
            assert f"CPM field {field_name} is not supported" in message
        else:
            raise AssertionError(f"CPM side channel {field_name} was consumed")


assert_load_rejects("upstreamEmulation")
assert_load_rejects("providerAccess")

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
)
setattr(runtime_site, "upstream_emulation", side_channel_payload)
setattr(runtime_site, "provider_access", side_channel_payload)

assert render_lab_emulation_artifacts(runtime_site) == []
topology = render_site_topology(runtime_site)
nodes = topology["topology"]["nodes"]
core_exec = "\n".join(nodes["clab-router-core-simulated-isp"]["exec"])
assert "sat-clab-pppoe-ac" not in nodes
assert "pppd pty" not in core_exec
assert "pppoe -I eth1" not in core_exec
assert "udhcpc -b -i eth1" in core_exec
assert "accept_ra=2" in core_exec
assert not any(
    "sat-clab-pppoe-ac:eth1" in link["endpoints"]
    for link in topology["topology"]["links"]
)

node_data = {
    "name": "clab-router-core-simulated-isp",
    "interfaces": {"pppoe-wan": {"kind": "wan"}},
    "upstreamEmulation": side_channel_payload,
    "providerAccess": side_channel_payload,
}
direct_pppoe = render_pppoe_runtime(
    "clab-router-core-simulated-isp",
    node_data,
    {"pppoe-wan": "eth1"},
)
assert direct_pppoe == []
direct_dynamic = "\n".join(render_dynamic_wan(node_data, {"pppoe-wan": "eth1"}))
assert "udhcpc -b -i eth1" in direct_dynamic
assert "pppd pty" not in direct_dynamic
PY

rg -q 'ppp' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
rg -q 'rp-pppoe' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
rg -q 'pppoe-sniff' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"

echo "PASS provider-access-side-channel-quarantine"
