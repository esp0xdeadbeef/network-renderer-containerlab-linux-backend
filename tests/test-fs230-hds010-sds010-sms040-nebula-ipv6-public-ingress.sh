#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-230-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_ROOT="${repo_root}" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from __future__ import annotations

import copy
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from clabgen.models import InterfaceModel, NodeModel
from clabgen.s88.CM.cpm_firewall_rules import rules_for_cpm_rule
from clabgen.s88.CM.linux_routes import _render_runtime_delegated_routes
from clabgen.s88.site.interface_model import _dict_list
from clabgen.s88.site.node_runtime import _protected_runtime_binds


SOURCE = "/run/secrets/lab-dmz-ipv6-prefix"
RUNTIME_DESTINATION = {
    "sourceClass": "protected",
    "source": "intent-routed-prefix",
    "sourceFile": SOURCE,
    "prefixName": "dmz-public",
    "interfaceIdentifier": "0:0:0:0:0:0:0:4242",
    "delegatedPrefixLength": 48,
    "perTenantPrefixLength": 64,
    "slot": 2,
    "targetPrefixLength": 128,
}
RULE = {
    "action": "accept",
    "relationId": "allow-wan-to-nebula-ipv6",
    "fromInterface": "ppp0",
    "toInterface": "core",
    "trafficType": "public-ingress",
    "matches": [{"family": "ipv6", "proto": "udp", "dports": [4242]}],
    "destinationPrefixes": [],
    "destinationRuntimeAddresses": [RUNTIME_DESTINATION],
}


commands = rules_for_cpm_rule(RULE)
assert len(commands) == 1, commands
command = commands[0]
assert "clab-protected-ipv6-materializer" in command
assert shlex.quote(SOURCE) in command
assert "--interface-identifier" in command
assert "meta nfproto ipv6" in command
assert "ip6 daddr" in command
assert "udp dport 4242" in command
assert " tcp " not in command
assert "|| true" not in command
assert "2001:db8" not in command

family_only = copy.deepcopy(RULE)
family_only.pop("destinationRuntimeAddresses")
family_only["destinationPrefixes"] = []
family_commands = rules_for_cpm_rule(family_only)
assert len(family_commands) == 1, family_commands
assert "udp dport 4242" in family_commands[0]

static = copy.deepcopy(family_only)
static["destinationPrefixes"] = [
    {"family": 6, "prefix": "2001:db8:230:2::4242/128"}
]
static_commands = rules_for_cpm_rule(static)
assert len(static_commands) == 1, static_commands
assert "ip6 daddr 2001:db8:230:2::4242/128" in static_commands[0]

for mutation in (
    lambda value: value["destinationRuntimeAddresses"][0].pop("sourceFile"),
    lambda value: value.update(destinationPrefixes=static["destinationPrefixes"]),
    lambda value: value["matches"][0].update(proto="icmpv6"),
):
    invalid = copy.deepcopy(RULE)
    mutation(invalid)
    try:
        rules_for_cpm_rule(invalid)
    except ValueError as error:
        assert "FS-230-HDS-010-SDS-010-SMS-040" in str(error)
    else:
        raise AssertionError("invalid runtime destination was accepted")

runtime_route = {
    "family": 6,
    "sourceFile": SOURCE,
    "delegatedPrefixLength": 48,
    "perTenantPrefixLength": 64,
    "slot": 2,
    "via6": "fd00:1000::1",
    "intent": {
        "kind": "runtime-routed-prefix-return",
        "source": "intent-routed-prefix",
    },
}
retained = _dict_list([runtime_route], "interface.routes.ipv6")
assert retained == [runtime_route]
node_data = {
    "interfaces": {
        "toward-target": {
            "addr6": "fd00:1000::2/127",
            "routes": {"ipv4": [], "ipv6": retained},
            "policyRoutingAllocation": {"tableId": 1002},
        },
        "other-lane": {
            "routes": {"ipv4": [], "ipv6": []},
            "policyRoutingAllocation": {"tableId": 1005},
        },
    }
}
route_commands = _render_runtime_delegated_routes(
    node_data, {"toward-target": "eth1", "other-lane": "eth2"}
)
assert len(route_commands) == 1, route_commands
route_command = route_commands[0]
assert "clab-protected-ipv6-materializer" in route_command
assert 'ip -6 route replace "$runtime_prefix"' in route_command
assert 'ip -6 route replace table 1002 "$runtime_prefix"' in route_command
assert 'ip -6 route replace table 1005 "$runtime_prefix"' in route_command
assert "2001:db8" not in route_command

node = NodeModel(
    name="core",
    role="core",
    routing_domain="lab",
    routing_mode="static",
    interfaces={
        "toward-target": InterfaceModel(
            name="toward-target",
            routes={"ipv4": [], "ipv6": [runtime_route]},
        )
    },
    forwarding_intent={"rules": [RULE]},
)
assert _protected_runtime_binds(node) == [f"{SOURCE}:{SOURCE}:ro"]

with tempfile.TemporaryDirectory() as raw_tmp:
    tmp = Path(raw_tmp)
    log = tmp / "commands.log"
    materializer = tmp / "clab-protected-ipv6-materializer"
    materializer.write_text(
        "#!/bin/sh\n"
        "case \" $* \" in\n"
        "  *' --interface-identifier '*) printf '%s\\n' '2001:db8:230:2::4242/128' ;;\n"
        "  *) printf '%s\\n' '2001:db8:230:2::/64' ;;\n"
        "esac\n"
    )
    materializer.chmod(0o755)
    nft = tmp / "nft"
    nft.write_text("#!/bin/sh\nprintf 'nft %s\\n' \"$*\" >>\"$COMMAND_LOG\"\n")
    nft.chmod(0o755)
    ip = tmp / "ip"
    ip.write_text("#!/bin/sh\nprintf 'ip %s\\n' \"$*\" >>\"$COMMAND_LOG\"\n")
    ip.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = f"{tmp}:/usr/bin:/bin"
    env["COMMAND_LOG"] = str(log)
    subprocess.run(command, shell=True, check=True, env=env)
    subprocess.run(route_command, shell=True, check=True, env=env)
    rendered = log.read_text()
    assert "ip6 daddr 2001:db8:230:2::4242/128" in rendered
    assert "udp dport 4242 counter accept" in rendered
    assert "route replace 2001:db8:230:2::/64" in rendered
    assert "route replace table 1002 2001:db8:230:2::/64" in rendered
    assert "route replace table 1005 2001:db8:230:2::/64" in rendered

print("PASS FS-230-HDS-010-SDS-010-SMS-040 CLAB protected IPv6 ingress contract")
PY

helper="${repo_root}/docker-clab-frr-plus-tooling/protected-ipv6-materializer.py"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
source_file="${tmp_dir}/prefix"
printf '%s\n' '2001:db8:230::/48' >"${source_file}"
derived_prefix="$(${helper} \
    --source "${source_file}" \
    --delegated-prefix-length 48 \
    --tenant-prefix-length 64 \
    --slot 2)"
test "${derived_prefix}" = '2001:db8:230:2::/64'
derived="$(${helper} \
    --source "${source_file}" \
    --delegated-prefix-length 48 \
    --tenant-prefix-length 64 \
    --slot 2 \
    --interface-identifier '::4242')"
test "${derived}" = '2001:db8:230:2::4242/128'

printf '%s\n' '2001:db8:230::/56' >"${source_file}"
if "${helper}" \
    --source "${source_file}" \
    --delegated-prefix-length 48 \
    --tenant-prefix-length 64 \
    --slot 2 \
    --interface-identifier '::4242' >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr"; then
    echo "invalid protected prefix accepted" >&2
    exit 1
fi
test ! -s "${tmp_dir}/stdout"
if grep -q '2001:db8' "${tmp_dir}/stderr"; then
    echo "protected prefix leaked in diagnostic" >&2
    exit 1
fi

printf 'PASS FS-230-HDS-010-SDS-010-SMS-040 protected Nebula IPv6 ingress CLAB rendering\n'
