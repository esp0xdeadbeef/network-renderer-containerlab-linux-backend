#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from copy import deepcopy

from clabgen.s88.CM.pppoe_runtime import render


ipv6 = {
    "mode": "dhcpv6-pd",
    "defaultRoute": True,
    "iaid": 7,
    "prefixDelegationRequestId": 11,
    "duidMode": "persistent",
    "resolverMode": "disabled",
    "ipv4Mode": "disabled",
    "routerSolicitation": False,
    "fallbackPolicy": "none",
}
client = {
    "interface": "provider-handoff",
    "runtimeInterface": "ppp-test",
    "defaultRoute": True,
    "usePeerDns": False,
    "mtu": 1492,
    "credentials": {
        "usernameFile": "/run/secrets/test-username",
        "passwordFile": "/run/secrets/test-password",
    },
    "ipv6": ipv6,
}


def rendered(value):
    node = {"services": {"pppoe": {"client": value}}}
    return "\n".join(render("test-core", node, {"provider-handoff": "eth1"}))


output = rendered(client)
for fragment in (
    "defaultroute6",
    "command -v dhcpcd",
    "nohook resolv.conf",
    "noipv6rs",
    "noipv4",
    "ipv6only",
    "interface ppp-test",
    "iaid 7",
    "ia_pd 11",
    "ip link show dev ppp-test",
    "dhcpcd -6 -d -B -f /etc/s88-pppoe-ipv6-pd.conf ppp-test",
    "nft add rule inet filter input iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546",
    'comment "s88-pppoe-dhcpv6-pd-replies"',
    "while :; do",
    "PPPoE DHCPv6-PD client exited; retrying",
):
    assert fragment in output, fragment
assert "udp dport 547" not in output
assert "ppp-test || true" not in output
assert "inet router" not in output
assert output.index("nohup pppd") < output.index("ip link show dev ppp-test")
assert output.index('comment "s88-pppoe-dhcpv6-pd-replies"') < output.index(
    "dhcpcd -6 -d -B"
)

mutations = {
    "missing-iaid": lambda value: value["ipv6"].pop("iaid"),
    "ipv4-enabled": lambda value: value["ipv6"].update(ipv4Mode="enabled"),
    "router-solicitation": lambda value: value["ipv6"].update(
        routerSolicitation=True
    ),
    "fallback-enabled": lambda value: value["ipv6"].update(fallbackPolicy="slaac"),
    "invented-interface": lambda value: value["ipv6"].update(
        inventedPppInterface="ppp0"
    ),
}
for case_name, mutate in mutations.items():
    candidate = deepcopy(client)
    mutate(candidate)
    try:
        rendered(candidate)
    except ValueError as error:
        diagnostic = str(error)
        assert "PPPoE IPv6/PD" in diagnostic
        assert "/run/secrets/test-" not in diagnostic
        assert "ppp-test" not in diagnostic
    else:
        raise AssertionError(f"{case_name} was accepted")

print("PASS FS-800-HDS-030-SDS-020-SMS-020: CLAB PPPoE IPv6/PD materialization")
PY

rg -F 'dhcpcd5' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile" >/dev/null
rg -F 'pppoe-server pppoe-sniff dhcpcd udhcpc' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile" >/dev/null
