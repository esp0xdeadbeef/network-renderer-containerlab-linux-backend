#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-010-SMS-070
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat >"${tmp_dir}/cpm.json" <<'JSON'
{
  "enterprise": {
    "esp0xdeadbeef": {
      "site": {
        "deploy-app": {
          "nodes": {
            "edge-a": {
              "role": "core",
              "routing_mode": "static",
              "routingDomain": "core",
              "loopback": {
                "ipv4": "10.255.0.1/32",
                "ipv6": "2001:db8:ffff::1/128"
              },
              "interfaces": {
                "to-edge-b": {
                  "runtimeIfName": "eth1",
                  "kind": "wan",
                  "addr4": "192.0.2.0/31",
                  "addr6": "2001:db8:100::/127"
                }
              }
            },
            "edge-b": {
              "role": "core",
              "routing_mode": "static",
              "routingDomain": "core",
              "loopback": {
                "ipv4": "10.255.0.2/32",
                "ipv6": "2001:db8:ffff::2/128"
              },
              "interfaces": {
                "to-edge-a": {
                  "runtimeIfName": "eth1",
                  "kind": "wan",
                  "addr4": "192.0.2.1/31",
                  "addr6": "2001:db8:100::1/127"
                }
              }
            }
          },
          "links": {
            "edge-a-b": {
              "kind": "wan",
              "bridge": "br-fs960",
              "endpoints": {
                "edge-a": { "interface": "to-edge-b" },
                "edge-b": { "interface": "to-edge-a" }
              }
            }
          }
        }
      }
    }
  }
}
JSON

cat >"${tmp_dir}/renderer-inventory.json" <<'JSON'
{
  "containerlab": {}
}
JSON

deploy_app="$(nix build --show-trace --print-out-paths --no-link "path:${repo_root}#deploy-clab")"

"${deploy_app}/bin/deploy-clab" --help >/dev/null

if "${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${tmp_dir}/bad" \
  "${tmp_dir}/intent.nix" \
  "${tmp_dir}/renderer-inventory.json" >"${tmp_dir}/bad.stdout" 2>"${tmp_dir}/bad.stderr"; then
  echo "deploy-clab accepted intent/inventory Nix input" >&2
  exit 1
fi
grep -F 'prebuilt CPM JSON' "${tmp_dir}/bad.stderr" >/dev/null

"${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${tmp_dir}/run" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory.json" >"${tmp_dir}/dry-run.log"

test -s "${tmp_dir}/run/fabric.clab.yml"
test -s "${tmp_dir}/run/vm-bridges-generated.nix"
test -s "${tmp_dir}/run/clab-bridge-plan.json"

grep -F 'clab.link.bridge: br-fs960' "${tmp_dir}/run/fabric.clab.yml" >/dev/null
jq -e '.bridgeNames == ["br-fs960"]' "${tmp_dir}/run/clab-bridge-plan.json" >/dev/null
grep -F 'would ensure Docker tooling image cache, cleanup fabric, materialize bridges, deploy, and verify containers' \
  "${tmp_dir}/dry-run.log" >/dev/null

echo "PASS deploy-clab-app-contract"
