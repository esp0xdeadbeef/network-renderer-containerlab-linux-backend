#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-020-SMS-010
# GAMP-SCOPE: software-integration-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

python3 - <<'PY'
import copy
import json
import tempfile
from pathlib import Path

from clabgen.models import InterfaceModel, LinkModel, NodeModel, SiteModel
from clabgen.s88.CM.lab_emulation import render_lab_emulation_artifacts
from clabgen.s88.CM.linux_wan_dynamic import render as render_dynamic_wan
from clabgen.s88.CM.pppoe_runtime import render as render_pppoe_runtime
from clabgen.s88.enterprise.enterprise import Enterprise
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

explicit_client_node = {
    "name": "clab-router-core-simulated-isp",
    "interfaces": {"pppoe-wan": {"kind": "wan"}},
    "services": {
        "pppoe": {
            "client": {
                "interface": "pppoe-wan",
                "runtimeInterface": "ppp0",
                "defaultRoute": True,
                "usePeerDns": True,
                "mtu": 1492,
                "credentials": {"username": "hat-pppoe", "password": "hat-pppoe"},
            }
        }
    },
}
explicit_client = "\n".join(
    render_pppoe_runtime(
        "clab-router-core-simulated-isp",
        explicit_client_node,
        {"pppoe-wan": "eth1"},
    )
)
assert "pppd pty" in explicit_client
assert "pppoe -I eth1" in explicit_client
assert "ifname ppp0" in explicit_client
assert "defaultroute replacedefaultroute" in explicit_client
assert "usepeerdns" in explicit_client
assert "mkdir -p /etc/ppp /run/ppp /run/pppd" in explicit_client
assert "pkill -x pppd" in explicit_client
assert "pkill -f 'pppoe -I eth1'" not in explicit_client
explicit_client_dynamic = "\n".join(
    render_dynamic_wan(explicit_client_node, {"pppoe-wan": "eth1"})
)
assert "udhcpc -b -i eth1" not in explicit_client_dynamic
assert "accept_ra=2" not in explicit_client_dynamic

explicit_server_node = {
    "name": "sat-clab-pppoe-ac",
    "interfaces": {"provider-handoff": {"kind": "wan"}},
    "services": {
        "pppoe": {
            "server": {
                "interface": "provider-handoff",
                "providerAddress": "203.0.113.5",
                "customerAddress": "203.0.113.4",
                "maxSessions": 32,
                "mtu": 1492,
                "credentials": {"username": "hat-pppoe", "password": "hat-pppoe"},
            }
        }
    },
}
explicit_server = "\n".join(
    render_pppoe_runtime(
        "sat-clab-pppoe-ac",
        explicit_server_node,
        {"provider-handoff": "eth2"},
    )
)
assert "pppoe-server" in explicit_server
assert "-I eth2" in explicit_server
assert "-L 203.0.113.5" in explicit_server
assert "-R 203.0.113.4" in explicit_server
assert "mkdir -p /etc/ppp /run/ppp" in explicit_server
assert "pkill -x pppoe-server" in explicit_server
assert "pkill -f 'pppoe-server -I eth2'" not in explicit_server


def render_cpm(cpm):
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "cpm.json"
        path.write_text(json.dumps(cpm))
        return Enterprise.from_solver_json(path, renderer_inventory={}).render()


positive_cpm = {
    "control_plane_model": {
        "version": 1,
        "data": {
            "esp0xdeadbeef": {
                "site-b-clab-pppoe": {
                    "runtimeTargets": {
                        "provider-runtime": {
                            "role": "access",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp0xdeadbeef",
                                "site": "site-b-clab-pppoe",
                                "name": "pppoe-provider",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "pppoe-handoff": {
                                        "kind": "wan",
                                        "runtimeIfName": "eth1",
                                        "attach": {"bridge": "br-clab-pppoe"},
                                        "backingRef": {"name": "pppoe-handoff"},
                                    }
                                }
                            },
                            "services": {
                                "pppoe": {
                                    "server": {
                                        "interface": "pppoe-handoff",
                                        "providerAddress": "203.0.113.5",
                                        "customerAddress": "203.0.113.4",
                                        "maxSessions": 8,
                                        "mtu": 1492,
                                        "credentials": {
                                            "username": "hat-pppoe",
                                            "password": "hat-pppoe",
                                        },
                                    }
                                }
                            },
                        },
                        "customer-runtime": {
                            "role": "core",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp0xdeadbeef",
                                "site": "site-b-clab-pppoe",
                                "name": "pppoe-customer",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "pppoe-handoff": {
                                        "kind": "wan",
                                        "runtimeIfName": "eth1",
                                        "attach": {"bridge": "br-clab-pppoe"},
                                        "backingRef": {"name": "pppoe-handoff"},
                                    }
                                }
                            },
                            "services": {
                                "pppoe": {
                                    "client": {
                                        "interface": "pppoe-handoff",
                                        "runtimeInterface": "ppp0",
                                        "defaultRoute": True,
                                        "usePeerDns": True,
                                        "mtu": 1492,
                                        "credentials": {
                                            "username": "hat-pppoe",
                                            "password": "hat-pppoe",
                                        },
                                    }
                                }
                            },
                        },
                    },
                    "transit": {
                        "adjacencies": [
                            {
                                "link": "pppoe-handoff",
                                "kind": "lan",
                                "endpoints": [
                                    {"unit": "pppoe-provider"},
                                    {"unit": "pppoe-customer"},
                                ],
                            }
                        ]
                    },
                }
            }
        },
    }
}

positive_render = render_cpm(positive_cpm)
positive_nodes = positive_render["topology"]["nodes"]
customer_name = next(
    name for name in positive_nodes if name.endswith("-pppoe-customer")
)
provider_name = next(
    name for name in positive_nodes if name.endswith("-pppoe-provider")
)
customer_exec = "\n".join(positive_nodes[customer_name]["exec"])
provider_exec = "\n".join(positive_nodes[provider_name]["exec"])
assert "pppd pty" in customer_exec
assert "pppoe -I eth1" in customer_exec
assert "udhcpc -b -i eth1" not in customer_exec
assert "accept_ra=2" not in customer_exec
assert "mkdir -p /etc/ppp /run/ppp /run/pppd" in customer_exec
assert "pkill -x pppd" in customer_exec
assert "pkill -f 'pppoe -I eth1'" not in customer_exec
assert "pppoe-server -I eth1" in provider_exec
assert "udhcpc -b -i eth1" not in provider_exec
assert "accept_ra=2" not in provider_exec
assert "mkdir -p /etc/ppp /run/ppp" in provider_exec
assert "pkill -x pppoe-server" in provider_exec
assert "pkill -f 'pppoe-server -I eth1'" not in provider_exec

missing_client = copy.deepcopy(positive_cpm)
del missing_client["control_plane_model"]["data"]["esp0xdeadbeef"][
    "site-b-clab-pppoe"
]["runtimeTargets"]["customer-runtime"]
del missing_client["control_plane_model"]["data"]["esp0xdeadbeef"][
    "site-b-clab-pppoe"
]["transit"]
try:
    render_cpm(missing_client)
except ValueError as exc:
    assert "requires exactly one client and one server" in str(exc)
    assert "clients=['<none>']" in str(exc)
    assert "servers=['pppoe-provider:pppoe-handoff']" in str(exc)
else:
    raise AssertionError("client-missing PPPoE render was accepted")

missing_server = copy.deepcopy(positive_cpm)
del missing_server["control_plane_model"]["data"]["esp0xdeadbeef"][
    "site-b-clab-pppoe"
]["runtimeTargets"]["provider-runtime"]
del missing_server["control_plane_model"]["data"]["esp0xdeadbeef"][
    "site-b-clab-pppoe"
]["transit"]
try:
    render_cpm(missing_server)
except ValueError as exc:
    assert "requires exactly one client and one server" in str(exc)
    assert "clients=['pppoe-customer:pppoe-handoff']" in str(exc)
    assert "servers=['<none>']" in str(exc)
else:
    raise AssertionError("server-missing PPPoE render was accepted")
PY

rg -q 'ppp' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
rg -q 'pppoe' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
rg -q 'pppoe-sniff' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"

echo "PASS provider-access-side-channel-quarantine"
