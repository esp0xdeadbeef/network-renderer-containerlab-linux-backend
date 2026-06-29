#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# CLAB DNS resolver materialization construction test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.CM.dns_service import render_dns_resolver_config, render_dns_service
from clabgen.s88.CM.linux_runtime import render
from clabgen.cpm_solver import cpm_site_to_solver_site
from clabgen.s88.site.model_builder import build_nodes, tenant_prefix_owners
from clabgen.s88.site.node_runtime import build_node_data


def node_with_resolver(source, resolver4=None, resolver6=None):
    return {
        "routing_mode": "static",
        "interfaces": {
            "eth0": {
                "runtimeIfName": "eth0",
                "dnsResolver": {
                    "resolver4": resolver4,
                    "resolver6": resolver6,
                    "resolverSource": source,
                }
            }
        },
    }


def rendered_text(cmds):
    return "\n".join(cmds)


def assert_no_host_public_resolver(text):
    forbidden = ("nameserver 1.1.1.1", "nameserver 8.8.8.8", "nameserver 9.9.9.9", "nameserver 192.168.1.1")
    for value in forbidden:
        assert value not in text, f"renderer emitted forbidden fallback {value}"


def assert_before(text, first, second):
    first_index = text.find(first)
    second_index = text.find(second)
    assert first_index != -1, f"missing expected text: {first}"
    assert second_index != -1, f"missing expected text: {second}"
    assert first_index < second_index, f"expected {first} before {second}"


# Positive: explicit local-recursive resolver addresses are consumed.
local_text = rendered_text(render_dns_resolver_config(node_with_resolver("local-recursive", "127.0.0.1", "::1")))
assert "FS-540-HDS-010-SDS-010-SMS-020" in local_text
assert "nameserver 127.0.0.1" in local_text
assert "nameserver ::1" in local_text
assert_no_host_public_resolver(local_text)
print("PASS local-recursive resolver materialized from CPM dnsResolver fields")


# Seeded negative guard: upstream-forwarder with no resolver address must still
# suppress Docker's generated host/public resolv.conf rather than inheriting it.
upstream_text = rendered_text(render_dns_resolver_config(node_with_resolver("upstream-forwarder")))
assert "No nameserver emitted by CPM dnsResolver authority" in upstream_text
assert "options timeout:1 attempts:1" in upstream_text
assert_no_host_public_resolver(upstream_text)
print("PASS upstream-forwarder without resolver address suppresses Docker host fallback")


# Seeded negative guard: resolverSource none is explicit no-DNS authority and
# must not inherit host/public resolvers.
none_text = rendered_text(render_dns_resolver_config(node_with_resolver("none")))
assert "No nameserver emitted by CPM dnsResolver authority" in none_text
assert_no_host_public_resolver(none_text)
print("PASS none resolver authority suppresses Docker host fallback")


# DNS-service nodes are owned by render_dns_service, which writes loopback
# resolvers and starts the local proxy.
service_node = node_with_resolver("local-recursive", "127.0.0.1", "::1")
service_node["services"] = {
    "dns": {
        "listen": ["10.50.10.1", "fd42:dead:feed:10::1"],
        "forwarders": ["1.1.1.1", "2606:4700:4700::1111"],
        "outgoingInterfaces": ["10.50.10.1", "fd42:dead:feed:10::1"],
        "killSwitch": {"blockPublicResolvers": True},
        "deniedResolverCidrs": ["1.1.1.1", "2606:4700:4700::1111"],
    }
}
assert render_dns_resolver_config(service_node) == []
service_text = rendered_text(render_dns_service(service_node))
assert "nameserver 127.0.0.1" in service_text
assert "clabgen-dns-proxy.py" in service_text
assert_no_host_public_resolver(service_text)
assert_before(
    service_text,
    "output ip saddr 10.50.10.1 ip daddr 1.1.1.1 udp dport 53 accept comment allow-dns-service-egress",
    "output ip daddr 1.1.1.1 udp dport 53 drop comment deny-public-dns-output-leak",
)
assert_before(
    service_text,
    "output ip6 saddr fd42:dead:feed:10::1 ip6 daddr 2606:4700:4700::1111 udp dport 53 accept comment allow-dns-service-egress",
    "output ip6 daddr 2606:4700:4700::1111 udp dport 53 drop comment deny-public-dns-output-leak",
)
print("PASS DNS service keeps local proxy resolv.conf ownership")


# Integration: linux_runtime includes resolver config for non-DNS nodes.
runtime_text = rendered_text(render("core", "core-nebula", node_with_resolver("none"), {}))
assert "FS-540-HDS-010-SDS-010-SMS-020" in runtime_text
assert "No nameserver emitted by CPM dnsResolver authority" in runtime_text
assert_no_host_public_resolver(runtime_text)
print("PASS linux_runtime emits controlled resolv.conf for non-DNS node")


# Live-shape integration: CPM runtimeTargets effectiveRuntimeRealization must
# preserve dnsResolver through the CPM -> solver -> S88 node model path.
cpm_site = {
    "runtimeTargets": {
        "esp-clab-clab-router-core-nebula": {
            "logicalNode": {"name": "clab-router-core-nebula"},
            "role": "core",
            "routingMode": "static",
            "effectiveRuntimeRealization": {
                "interfaces": {
                    "tenant-client": {
                        "runtimeIfName": "client",
                        "sourceKind": "tenant",
                        "tenant": "client",
                        "dnsResolver": {
                            "resolver4": None,
                            "resolver6": None,
                            "resolverSource": "upstream-forwarder",
                        },
                    }
                }
            },
        }
    }
}
solver_site = cpm_site_to_solver_site(cpm_site)
nodes = build_nodes(solver_site, tenant_prefix_owners(solver_site))
core_node = nodes["clab-router-core-nebula"]
core_map = {"tenant-client": "client"}
core_data = build_node_data("clab-router-core-nebula", core_node, core_map)
core_text = rendered_text(
    render(
        "core",
        "clab-router-core-nebula",
        core_data,
        core_map,
    )
)
assert "FS-540-HDS-010-SDS-010-SMS-020" in core_text
assert "No nameserver emitted by CPM dnsResolver authority" in core_text
assert_no_host_public_resolver(core_text)
print("PASS CPM runtimeTargets dnsResolver survives into CLAB linux_runtime")


print("PASS FS-540-HDS-010-SDS-010-SMS-020 CLAB DNS resolver materialization")
PY
