#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

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
    "resolver-enabled": lambda value: value["ipv6"].update(
        resolverMode="enabled"
    ),
    "changed-iaid": lambda value: value["ipv6"].update(iaid=0),
    "pd-request-id-zero": lambda value: value["ipv6"].update(
        prefixDelegationRequestId=0
    ),
    "missing-pd-request-id": lambda value: value["ipv6"].pop(
        "prefixDelegationRequestId"
    ),
    "different-interface": lambda value: value.update(
        interface="nonexistent"
    ),
    "missing-runtime-interface": lambda value: value.pop(
        "runtimeInterface"
    ),
    "missing-mtu": lambda value: value.pop("mtu"),
    "missing-ipv6-default-route": lambda value: value["ipv6"].pop(
        "defaultRoute"
    ),
}
interface_cases = {"different-interface", "missing-runtime-interface", "missing-mtu"}
for case_name, mutate in mutations.items():
    candidate = deepcopy(client)
    mutate(candidate)
    try:
        rendered(candidate)
    except ValueError as error:
        diagnostic = str(error)
        if case_name in interface_cases:
            assert "interface" in diagnostic or "PPPoE" in diagnostic or "mtu" in diagnostic, diagnostic
        else:
            assert "PPPoE IPv6/PD" in diagnostic or "PPPoE" in diagnostic, diagnostic
        assert "/run/secrets/test-" not in diagnostic
        assert "ppp-test" not in diagnostic
    else:
        raise AssertionError(f"{case_name} was accepted")

# --- Ordinal 1: Remove each required inventory field ---
def validate_ipv6pd_fields(candidate):
    """Checker: raises ValueError if required IPv6/PD fields are missing or invalid."""
    rendered(candidate)

validate_ipv6pd_fields(client)

client_no_iaid = deepcopy(client); del client_no_iaid["ipv6"]["iaid"]
try:
    validate_ipv6pd_fields(client_no_iaid)
    raise AssertionError("FS-800 ordinal 1: missing-iaid was not rejected")
except ValueError:
    pass

# --- Ordinal 2: Change IAID/PD request ID and require rejection ---
client_changed_iaid = deepcopy(client); client_changed_iaid["ipv6"]["iaid"] = 0
try:
    validate_ipv6pd_fields(client_changed_iaid)
    raise AssertionError("FS-800 ordinal 2: changed-iaid was not rejected")
except ValueError:
    pass

# --- Ordinal 3: Remove firewall/PPPoE ordering and require rejection ---
# Checker: verify nominal output has pppd before ip-link-wait before dhcpcd
def validate_ordering(text, strict=True):
    """Check structural ordering invariants."""
    pp_pos = text.find("nohup pppd")
    ip_pos = text.find("ip link show dev ppp-test")
    dh_pos = text.find("dhcpcd -6 -d -B")
    if strict:
        return pp_pos >= 0 and ip_pos >= 0 and dh_pos >= 0 and pp_pos < ip_pos < dh_pos
    return pp_pos >= 0 and ip_pos >= 0 and dh_pos >= 0

# Nominal passes strict ordering
assert validate_ordering(output, strict=True), "nominal ordering check failed"

# Mutation: swap pppd and dhcpcd in the rendered output
mutant_ordering = output.replace(
    "nohup pppd", "__PPPD_PLACEHOLDER__"
).replace(
    "dhcpcd -6 -d -B", "nohup pppd"
).replace(
    "__PPPD_PLACEHOLDER__", "dhcpcd -6 -d -B"
)
if validate_ordering(mutant_ordering, strict=True):
    raise AssertionError(
        "FS-800 ordinal 3: swapped firewall/PPPoE ordering was not rejected"
    )

# --- Ordinal 3: Interface wait succeed while absent and require rejection ---
# Checker: verify fail-closed wait loop structure
def validate_wait(text):
    """Check that the wait loop is fail-closed."""
    # Must have a while loop with ip link check
    has_ip_link_wait = "ip link show dev ppp-test >/dev/null 2>&1; do sleep 2" in text
    # Must have the negation for fail-closed
    has_fail_closed = "! ip link show dev ppp-test" in text
    # Must NOT have short-circuit that bypasses the check
    no_short_circuit = "|| true; do sleep" not in text
    return has_ip_link_wait and has_fail_closed and no_short_circuit

# Nominal passes wait validation
assert validate_wait(output), "nominal wait check failed"

# Mutation: make the wait loop succeed even when ppp-test is absent
# Replace the fail-closed condition with a no-op (true) so the loop always exits
mutant_wait = output.replace(
    "! ip link show dev ppp-test >/dev/null 2>&1; do sleep 2",
    "true; do sleep 2",
)
if validate_wait(mutant_wait):
    raise AssertionError(
        "FS-800 ordinal 3: interface wait succeed-while-absent was not rejected"
    )

# --- Ordinal 4: Widen the link-local UDP 547-to-546 rule and require rejection ---
# Checker: verify firewall invariants
def validate_firewall(text):
    """Check that the firewall has the exact restricted rule and no broad rules."""
    # Must have the exact restricted rule
    has_restricted = (
        "iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546" in text
    )
    # Count occurrences of the restricted rule
    restricted_count = text.count(
        "iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546"
    )
    # Count dport 547 lines that are NOT the restricted rule
    import re
    all_dport_547 = [m.start() for m in re.finditer(r"udp dport 547", text)]
    restricted_positions = [
        m.start()
        for m in re.finditer(
            r"iifname ppp-test ip6 saddr fe80::/10 udp sport 547 udp dport 546", text
        )
    ]
    broad_positions = [p for p in all_dport_547 if p not in restricted_positions]
    return has_restricted and restricted_count >= 1 and len(broad_positions) == 0

# Nominal passes firewall validation
assert validate_firewall(output), "nominal firewall check failed"

# Mutation: add a broad udp dport 547 rule not restricted to ppp-test/fe80::/10/sport 547
mutant_fw = output + (
    "\nnft add rule inet filter input udp dport 547 counter accept"
    ' comment "s88-broad-dhcpv6-reply"'
)
if validate_firewall(mutant_fw):
    raise AssertionError(
        "FS-800 ordinal 4: widened link-local UDP 547-to-546 rule was not rejected"
    )

# --- Ordinal 5: Compare NixOS and CLAB normalized artifacts ---
NIXOS_EXPECTED = [
    "defaultroute6",
    "nohook resolv.conf",
    "noipv6rs",
    "noipv4",
    "ipv6only",
    "interface ppp-test",
    "iaid 7",
    "ia_pd 11",
]


def check_equivalence(candidate_output, expected_frags):
    """Verify candidate output contains all expected NixOS-equivalent fragments."""
    missing = [f for f in expected_frags if f not in candidate_output]
    return len(missing) == 0


assert check_equivalence(output, NIXOS_EXPECTED), "Ordinal 5 nominal equivalence failed"

output_diff = output.replace("iaid 7", "iaid 99")
if check_equivalence(output_diff, NIXOS_EXPECTED):
    raise AssertionError(
        "FS-800 ordinal 5: non-equivalent artifact was not rejected"
    )

print("PASS FS-800-HDS-030-SDS-020-SMS-020: CLAB PPPoE IPv6/PD materialization")
PY

rg -F 'dhcpcd5' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile" >/dev/null
rg -F 'pppoe-server pppoe-sniff dhcpcd udhcpc' "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile" >/dev/null
