#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.site.model_builder import build_nodes
from clabgen.s88.site.node_runtime import render_linux_node


def assert_has(text, needle):
    if needle not in text:
        raise AssertionError(f"missing {needle!r} in:\n{text}")


def assert_not_has(text, needle):
    if needle in text:
        raise AssertionError(f"forbidden {needle!r} in:\n{text}")


site = {
    "runtimeTargets": {
        "access-runtime": {
            "logicalNode": {
                "enterprise": "esp",
                "site": "clab",
                "name": "access-client",
            },
            "advertisements": {
                "dhcp4": [
                    {
                        "enabled": True,
                        "bindInterface": "tenant-client",
                        "subnet": "10.50.20.0/24",
                        "pool": {
                            "start": "10.50.20.100",
                            "end": "10.50.20.200",
                        },
                        "routerAddress": "10.50.20.1",
                        "dnsServers": ["10.50.20.1"],
                        "domain": "lan.",
                        "reservations": [],
                    }
                ],
                "ipv6Ra": [
                    {
                        "enabled": True,
                        "bindInterface": "tenant-client",
                        "prefixes": ["fd42:dead:beef:20::/64"],
                    }
                ],
            },
        },
        "provider-runtime": {
            "logicalNode": {
                "enterprise": "esp",
                "site": "clab",
                "name": "provider-handoff-access-a",
            },
            "advertisements": {
                "dhcp4": [
                    {
                        "enabled": False,
                        "bindInterface": "tenant-provider-handoff-a",
                    }
                ],
                "ipv6Ra": [
                    {
                        "enabled": False,
                        "bindInterface": "tenant-provider-handoff-a",
                    }
                ],
            },
        },
    },
    "nodes": {
        "access-client": {
            "role": "access",
            "routing_mode": "static",
            "routingDomain": "default",
            "interfaces": {
                "fabric": {
                    "kind": "lan",
                    "addr4": "10.50.0.2/31",
                    "routes": {},
                },
                "tenant-client": {
                    "kind": "tenant",
                    "tenant": "client",
                    "addr4": "10.50.20.1/24",
                    "addr6": "fd42:dead:beef:20::1/64",
                    "routes": {},
                },
            },
        },
        "provider-handoff-access-a": {
            "role": "access",
            "routing_mode": "static",
            "routingDomain": "default",
            "interfaces": {
                "fabric": {
                    "kind": "lan",
                    "addr4": "10.50.0.4/31",
                    "routes": {},
                },
                "tenant-provider-handoff-a": {
                    "kind": "tenant",
                    "tenant": "provider-handoff-a",
                    "addr4": "10.80.0.1/24",
                    "addr6": "fd42:dead:beef:80::1/64",
                    "routes": {},
                },
            },
        },
    },
    "links": {},
}

nodes = build_nodes(site, {})
access = render_linux_node(
    "access-client",
    nodes["access-client"],
    {"fabric": "eth1", "tenant-client": "eth2"},
)
access_text = "\n".join(access["exec"])

assert_has(access_text, "udhcpd /run/udhcpd.eth2.conf")
assert_has(access_text, "interface eth2")
assert_has(access_text, "start 10.50.20.100")
assert_has(access_text, "end 10.50.20.200")
assert_has(access_text, "option router 10.50.20.1")
assert_has(access_text, "option dns 10.50.20.1")
assert_has(access_text, "command -v vtysh")
assert_has(access_text, "no ipv6 nd suppress-ra")
assert_has(access_text, "ipv6 nd ra-interval 30")
assert_has(access_text, "ipv6 nd prefix fd42:dead:beef:20::/64")
assert_not_has(access_text, "radvd")

provider = render_linux_node(
    "provider-handoff-access-a",
    nodes["provider-handoff-access-a"],
    {"fabric": "eth1", "tenant-provider-handoff-a": "eth2"},
)
provider_text = "\n".join(provider["exec"])
assert_not_has(provider_text, "udhcpd /run/udhcpd.eth2.conf")
assert_not_has(provider_text, "radvd")

print("PASS access-advertisements-runtime")
PY
