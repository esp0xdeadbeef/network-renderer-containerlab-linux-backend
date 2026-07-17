#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
materializer="${repo_root}/docker-clab-frr-plus-tooling/protected-reservation-materializer.py"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.site.model_builder import build_nodes
from clabgen.s88.site.node_runtime import render_linux_node


source_file = "/run/secrets/fs970-clab-protected-reservations.json"
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
                    "domain": "lan.", "reservations": [],
                    "reservationSource": {
                        "schema": "gamp-protected-reservation-set-v1",
                        "sourceClass": "protected", "sourceFile": source_file,
                        "family": "ipv4",
                    },
                }],
                "dhcpv6": [{
                    "id": "client", "enabled": True, "bindInterface": "tenant-client",
                    "subnet": "fd42:dead:beef:20::/64",
                    "pool": {"start": "fd42:dead:beef:20::100", "end": "fd42:dead:beef:20::1ff"},
                    "dnsServers": ["fd42:dead:beef:20::1"], "domain": "lan.",
                    "reservations": [],
                    "reservationSource": {
                        "schema": "gamp-protected-reservation-set-v1",
                        "sourceClass": "protected", "sourceFile": source_file,
                        "family": "ipv6",
                    },
                }],
                "ipv6Ra": [{
                    "enabled": True, "bindInterface": "tenant-client",
                    "prefixes": ["fd42:dead:beef:20::/64"],
                    "managed": True, "otherConfig": True,
                    "onLink": True, "autonomous": False,
                }],
            },
        },
    },
    "nodes": {
        "access-client": {
            "role": "access", "routing_mode": "static", "routingDomain": "default",
            "interfaces": {
                "tenant-client": {
                    "kind": "tenant", "tenant": "client",
                    "addr4": "10.50.20.1/24", "addr6": "fd42:dead:beef:20::1/64",
                    "routes": {},
                },
            },
        },
    },
    "links": {},
}

node = build_nodes(site, {})["access-client"]
rendered = render_linux_node("access-client", node, {"tenant-client": "eth1"})
text = "\n".join(rendered["exec"])

assert rendered["binds"] == [f"{source_file}:{source_file}:ro"]
for required in (
    "clab-protected-reservation-materializer --family ipv4",
    "clab-protected-reservation-materializer --family ipv6",
    "kea-dhcp4 -d -c /run/kea/eth1-dhcp4.json",
    "kea-dhcp6 -d -c /run/kea/eth1-dhcp6.json",
    "ipv6 nd managed-config-flag",
    "ipv6 nd other-config-flag",
    "ipv6 nd prefix fd42:dead:beef:20::/64 no-autoconfig",
):
    assert required in text, required
assert "udhcpd /run/udhcpd.eth1.conf" not in text
assert "protected-client-serial" not in text
assert "02:00:00:00:00:70" not in text

bad = site["runtimeTargets"]["access-runtime"]["advertisements"]["dhcp4"][0]
bad["reservationSource"] = dict(bad["reservationSource"], sourceFile="/tmp/plain.json")
try:
    render_linux_node(
        "access-client", build_nodes(site, {})["access-client"], {"tenant-client": "eth1"}
    )
except ValueError as error:
    assert str(error) == "diagnostic.runtime-reservation-source-path-invalid"
else:
    raise AssertionError("unapproved protected source path was accepted")

print("PASS FS-970 CLAB protected source render and fail-closed boundary")
PY

source_file="${tmp_dir}/protected.json"
cat >"${source_file}" <<'JSON'
[
  {
    "id": "protected-probe",
    "scope": "client",
    "hostname": "protected-client-serial",
    "ipv4": {"address": "10.50.20.50", "mac-address": "02:00:00:00:00:70"},
    "ipv6": {
      "address": "fd42:dead:beef:20::abcd",
      "iid": "000000000000abcd",
      "iid-stability": "stable",
      "duid": "00:01:00:01:12:34:56:78:02:00:00:00:00:70",
      "iaid": 7
    }
  }
]
JSON
chmod 0400 "${source_file}"

cat >"${tmp_dir}/dhcp4-template.json" <<'JSON'
{"Dhcp4":{"subnet4":[{"reservations":[]}]}}
JSON
cat >"${tmp_dir}/dhcp6-template.json" <<'JSON'
{"Dhcp6":{"subnet6":[{"reservations":[]}]}}
JSON

"${materializer}" \
  --family ipv4 --scope client --subnet 10.50.20.0/24 \
  --pool '10.50.20.100 - 10.50.20.200' --source "${source_file}" \
  --template "${tmp_dir}/dhcp4-template.json" --output "${tmp_dir}/dhcp4.json"
"${materializer}" \
  --family ipv6 --scope client --subnet fd42:dead:beef:20::/64 \
  --pool 'fd42:dead:beef:20::100 - fd42:dead:beef:20::1ff' --source "${source_file}" \
  --template "${tmp_dir}/dhcp6-template.json" --output "${tmp_dir}/dhcp6.json"

jq -e '.Dhcp4.subnet4[0]
  | .["reservations-out-of-pool"] == true
    and (.reservations | length == 1)
    and .reservations[0]["ip-address"] == "10.50.20.50"
    and .reservations[0]["hw-address"] == "02:00:00:00:00:70"' \
  "${tmp_dir}/dhcp4.json" >/dev/null
jq -e '.Dhcp6.subnet6[0]
  | .["reservations-out-of-pool"] == true
    and (.reservations | length == 1)
    and .reservations[0]["ip-addresses"] == ["fd42:dead:beef:20::abcd"]
    and .reservations[0].duid == "00:01:00:01:12:34:56:78:02:00:00:00:00:70"' \
  "${tmp_dir}/dhcp6.json" >/dev/null
[[ "$(stat -c '%a' "${tmp_dir}/dhcp4.json")" == "600" ]]
[[ "$(stat -c '%a' "${tmp_dir}/dhcp6.json")" == "600" ]]

jq '.[0].ipv6.iid = "000000000000dcba"' "${source_file}" >"${tmp_dir}/bad-iid.json"
if "${materializer}" \
  --family ipv6 --scope client --subnet fd42:dead:beef:20::/64 \
  --pool 'fd42:dead:beef:20::100 - fd42:dead:beef:20::1ff' \
  --source "${tmp_dir}/bad-iid.json" --template "${tmp_dir}/dhcp6-template.json" \
  --output "${tmp_dir}/bad.json" >"${tmp_dir}/bad.out" 2>"${tmp_dir}/bad.err"; then
  echo "FAIL FS-970: mismatched IPv6 IID was accepted" >&2
  exit 1
fi
grep -Fx 'diagnostic.runtime-reservation-secret-record-invalid: protected reservation set or Kea template rejected' "${tmp_dir}/bad.err" >/dev/null
if grep -Eq 'protected-client-serial|02:00:00:00:00:70|fd42:dead:beef:20::abcd' "${tmp_dir}/bad.err"; then
  echo "FAIL FS-970: protected material leaked in diagnostics" >&2
  exit 1
fi

grep -F 'COPY protected-reservation-materializer.py /usr/local/bin/clab-protected-reservation-materializer' \
  "${repo_root}/docker-clab-frr-plus-tooling/Dockerfile" >/dev/null

echo "PASS FS-970-HDS-010-SDS-020-SMS-040: CLAB protected dual-stack reservation runtime"
