#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
materializer="${repo_root}/docker-clab-frr-plus-tooling/protected-reservation-materializer.py"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

PYTHONPATH="${repo_root}" python3 - <<'PY'
import copy

from clabgen.s88.site.model_builder import build_nodes
from clabgen.s88.site.node_runtime import render_linux_node


source_file = "/run/secrets/fs560-protected-reservations.json"
publication = {
    "namespace": "client.lan.",
    "ownerScope": "client",
    "requesterScopes": ["client"],
    "recordClasses": ["A", "AAAA", "PTR"],
    "fallbackBehavior": "local-only",
    "publicationDenialDiagnostic": "diagnostic.protected-reservation-name-publication-denied",
    "source": "protected-reservation-set",
    "sourceFamily": "ipv4",
}
source = {
    "schema": "gamp-protected-reservation-set-v1",
    "sourceClass": "protected",
    "sourceFile": source_file,
    "family": "ipv4",
    "namePublication": publication,
}
site = {
    "runtimeTargets": {
        "access-runtime": {
            "logicalNode": {"enterprise": "esp", "site": "clab", "name": "access-client"},
            "advertisements": {
                "dhcp4": [{
                    "id": "client", "enabled": True, "bindInterface": "tenant-client",
                    "subnet": "10.50.20.0/24",
                    "pool": {"start": "10.50.20.100", "end": "10.50.20.200"},
                    "routerAddress": "10.50.20.1", "dnsServers": ["10.50.20.1"],
                    "domain": "client.lan.", "reservations": [],
                    "reservationSource": source,
                }],
                "dhcpv6": [], "ipv6Ra": [],
            },
            "services": {
                "dns": {
                    "recursionMode": "iterative",
                    "listen": ["10.50.20.1"],
                    "allowFrom": ["10.50.20.0/24"],
                    "protectedReservationPublications": [{
                        "source": {key: source[key] for key in ("schema", "sourceClass", "sourceFile")},
                        "scopeId": "client",
                        "namespace": publication["namespace"],
                        "ownerScope": publication["ownerScope"],
                        "requesterScopes": publication["requesterScopes"],
                        "recordClasses": publication["recordClasses"],
                        "materializerFamily": "ipv4",
                        "fallbackBehavior": publication["fallbackBehavior"],
                        "publicationDenialDiagnostic": publication["publicationDenialDiagnostic"],
                    }],
                },
            },
        },
    },
    "nodes": {
        "access-client": {
            "role": "access", "routing_mode": "static", "routingDomain": "default",
            "interfaces": {
                "tenant-client": {
                    "kind": "tenant", "tenant": "client",
                    "addr4": "10.50.20.1/24", "routes": {},
                },
            },
        },
    },
    "links": {},
}

node = build_nodes(site, {})["access-client"]
rendered = render_linux_node("access-client", node, {"tenant-client": "eth1"})
text = "\n".join(rendered["exec"])
materializer_call = "clab-protected-reservation-materializer --family ipv4"
unbound_config = "cat >/tmp/clabgen-unbound.conf"
assert materializer_call in text
assert "--dns-output /run/protected-reservation-dns/client.conf" in text
assert "--dns-namespace client.lan." in text
assert "--dns-record-class A" in text
assert "--dns-record-class AAAA" in text
assert "--dns-record-class PTR" in text
assert 'include: "/run/protected-reservation-dns/client.conf"' in text
assert 'local-zone: "client.lan." static' in text
assert text.index(materializer_call) < text.index(unbound_config)
assert rendered["labels"]["clab.access-advertisements.runtime"] == "kea"
assert rendered["labels"]["clab.dns.runtime"] == "unbound"
for protected_value in (
    "private-device",
    "02:10:20:aa:bb:cc",
    "fd42:20::1234:5678:9abc:def0",
):
    assert protected_value not in text

bad_site = copy.deepcopy(site)
bad = bad_site["runtimeTargets"]["access-runtime"]["services"]["dns"]
bad["protectedReservationPublications"][0]["requesterScopes"] = ["*"]
try:
    render_linux_node(
        "access-client",
        build_nodes(bad_site, {})["access-client"],
        {"tenant-client": "eth1"},
    )
except ValueError as error:
    assert "unscoped protected reservation publication" in str(error)
    assert "10.50.20" not in str(error)
else:
    raise AssertionError("wildcard protected publication scope was accepted")

conflicting_site = copy.deepcopy(site)
conflicting_site["runtimeTargets"]["access-runtime"]["services"]["dns"]["localZones"] = [
    {"name": "client.lan.", "type": "transparent"}
]
try:
    render_linux_node(
        "access-client",
        build_nodes(conflicting_site, {})["access-client"],
        {"tenant-client": "eth1"},
    )
except ValueError as error:
    assert "conflicting protected reservation namespace authority" in str(error)
    assert "10.50.20" not in str(error)
else:
    raise AssertionError("conflicting protected publication namespace was accepted")

print("PASS FS-560 CLAB contract and init ordering")
PY

template="${tmp_dir}/kea-template.json"
secret="${tmp_dir}/protected.json"
kea_output="${tmp_dir}/kea.json"
dns_output="${tmp_dir}/protected-dns/client.conf"

printf '%s\n' '{"Dhcp4":{"subnet4":[{"reservations":[]}]}}' >"${template}"
printf '%s\n' '[{"id":"opaque-01","scope":"client","hostname":"private-device","ipv4":{"address":"10.50.20.10","mac-address":"02:10:20:aa:bb:cc"},"ipv6":{"address":"fd42:20::1234:5678:9abc:def0","iid":"123456789abcdef0","iid-stability":"stable","duid":"0001000123456789001122334455","iaid":7}}]' >"${secret}"

"${materializer}" \
  --family ipv4 --scope client --subnet 10.50.20.0/24 \
  --pool '10.50.20.100 - 10.50.20.200' \
  --source "${secret}" --template "${template}" --output "${kea_output}" \
  --dns-output "${dns_output}" --dns-namespace client.lan. \
  --dns-record-class A --dns-record-class AAAA --dns-record-class PTR \
  --dns-group "$(id -gn)"

grep -Fx '  local-data: "private-device.client.lan. IN A 10.50.20.10"' "${dns_output}" >/dev/null
grep -Fx '  local-data: "private-device.client.lan. IN AAAA fd42:20::1234:5678:9abc:def0"' "${dns_output}" >/dev/null
grep -Fx '  local-data-ptr: "10.50.20.10 private-device.client.lan."' "${dns_output}" >/dev/null
grep -Fx '  local-data-ptr: "fd42:20::1234:5678:9abc:def0 private-device.client.lan."' "${dns_output}" >/dev/null
[[ "$(stat -c '%a' "${dns_output}")" == "640" ]]
[[ "$(stat -c '%G' "${dns_output}")" == "$(id -gn)" ]]
if grep -F -e '02:10:20:aa:bb:cc' -e '0001000123456789001122334455' "${dns_output}" >/dev/null; then
  echo "FAIL FS-560: DHCP identities leaked into CLAB Unbound data" >&2
  exit 1
fi

unbound_out="$(nix eval --raw nixpkgs#unbound.outPath)"
printf 'include: "%s"\nserver:\n  username: ""\n  chroot: ""\n  directory: "/tmp"\n  pidfile: "%s"\n' \
  "${dns_output}" "${tmp_dir}/unbound.pid" >"${tmp_dir}/unbound.conf"
"${unbound_out}/bin/unbound-checkconf" "${tmp_dir}/unbound.conf" >/dev/null

escaped_secret="${tmp_dir}/escaped.json"
jq '.[0].hostname = "escape.other"' "${secret}" >"${escaped_secret}"
if "${materializer}" \
  --family ipv4 --scope client --subnet 10.50.20.0/24 \
  --pool '10.50.20.100 - 10.50.20.200' \
  --source "${escaped_secret}" --template "${template}" --output "${tmp_dir}/escaped-kea.json" \
  --dns-output "${tmp_dir}/escaped.conf" --dns-namespace client.lan. \
  --dns-record-class A --dns-group "$(id -gn)" \
  >"${tmp_dir}/escaped.out" 2>"${tmp_dir}/escaped.err"; then
  echo "FAIL FS-560: CLAB namespace escape was accepted" >&2
  exit 1
fi
grep -Fx 'diagnostic.runtime-reservation-secret-record-invalid: protected reservation set or Kea template rejected' "${tmp_dir}/escaped.err" >/dev/null
if grep -F -e 'escape.other' -e '10.50.20.10' "${tmp_dir}/escaped.err" >/dev/null; then
  echo "FAIL FS-560: protected values leaked in CLAB diagnostics" >&2
  exit 1
fi

echo "PASS FS-560-HDS-010-SDS-010-SMS-050: CLAB protected reservation A/AAAA/PTR materialization"
