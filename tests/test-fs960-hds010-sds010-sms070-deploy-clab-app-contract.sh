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

cat >"${tmp_dir}/renderer-inventory-lab-emulation.json" <<'JSON'
{
  "containerlab": {
    "capabilities": {
      "labEmulation": true
    },
    "labEmulation": {
      "scope": "harness",
      "requests": [
        {
          "providerEmulationMode": "fake-provider",
          "name": "fs540-dns-resolver-testnet",
          "handoffVlan": 11,
          "liveUpstreamVlan": 4,
          "dhcp4": {
            "address": "10.20.0.1/24",
            "router": "10.20.0.1",
            "rangeStart": "10.20.0.20",
            "rangeEnd": "10.20.0.99",
            "leaseTime": "5m",
            "sourcePrefix": "10.20.0.0/24"
          },
          "nat44": {
            "enabled": true,
            "sourcePrefix": "10.20.0.0/24"
          }
        }
      ]
    }
  },
  "deployment": {
    "hosts": {
      "s-router-clab": {
        "bridgeNetworks": {
          "testnet-vlan4": {
            "bridge": "testnet-vlan4",
            "mode": "vlan",
            "parent": "eth0",
            "vlan": 4
          }
        }
      }
    }
  }
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
test -s "${tmp_dir}/run/clab-renderer-deploy-provenance.json"

grep -F 'clab.link.bridge: br-fs960' "${tmp_dir}/run/fabric.clab.yml" >/dev/null
jq -e '.bridgeNames == ["br-fs960"]' "${tmp_dir}/run/clab-bridge-plan.json" >/dev/null
jq -e '
  .schema == "clab-renderer-deploy-provenance.v1"
  and .renderer.name == "network-renderer-containerlab-linux-backend"
  and (.renderer.identity | startswith("network-renderer-containerlab-linux-backend@"))
  and (
    (.renderer.rev | type == "string" and length > 6 and . != "unknown")
    or (.renderer.narHash | type == "string" and startswith("sha256-"))
  )
  and .renderer.revSource == "env"
  and .renderer.immutable == true
  and (.renderer.immutableProof == "git-rev" or .renderer.immutableProof == "narHash")
  and .locks.renderer.available == true
  and .artifacts.topology == "'"${tmp_dir}"'/run/fabric.clab.yml"
  and .artifacts.bridgePlan == "'"${tmp_dir}"'/run/clab-bridge-plan.json"
' "${tmp_dir}/run/clab-renderer-deploy-provenance.json" >/dev/null
grep -F 'would ensure Docker tooling image cache, cleanup fabric, materialize bridges, materialize lab emulation, deploy, and verify containers' \
  "${tmp_dir}/dry-run.log" >/dev/null
grep -F "renderer deploy provenance=${tmp_dir}/run/clab-renderer-deploy-provenance.json" \
  "${tmp_dir}/dry-run.log" >/dev/null

"${deploy_app}/bin/deploy-clab" \
  --dry-run \
  --work-dir "${tmp_dir}/lab-emulation" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory-lab-emulation.json" >"${tmp_dir}/lab-emulation-dry-run.log"

grep -F 'labEmulationArtifacts = builtins.fromJSON' "${tmp_dir}/lab-emulation/vm-bridges-generated.nix" >/dev/null
grep -F 'lab-emulation-fs540-dns-resolver-testnet:' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'clab.lab-emulation: fake-provider' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'ip addr replace 10.20.0.1/24 dev eth1' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'udhcpd /run/udhcpd/fake-provider.conf' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'ip saddr 10.20.0.0/24 masquerade' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'nft list chain ip nat postrouting' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'clab.link.type: lab-emulation' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
grep -F 'clab.link.bridge: testnet-vlan4' "${tmp_dir}/lab-emulation/fabric.clab.yml" >/dev/null
python3 - "${tmp_dir}/lab-emulation/vm-bridges-generated.nix" <<'PY'
import json
import re
import sys
from pathlib import Path

bridges = Path(sys.argv[1]).read_text()
quote = chr(39) * 2
pattern = r"bridgeNetworks = builtins\.fromJSON " + quote + r"\n(.*)\n  " + quote + ";"
match = re.search(pattern, bridges, re.S)
if not match:
    raise SystemExit("missing bridgeNetworks JSON")
bridge_networks = json.loads(match.group(1))
assert bridge_networks["testnet-vlan4"]["vlan"] == 4
PY
jq -e '
  (.bridgeNames | index("testnet-vlan4") != null)
  and .bridgeNetworks["testnet-vlan4"].mode == "vlan"
  and .bridgeNetworks["testnet-vlan4"].vlan == 4
  and (.labEmulationArtifacts | length == 1)
  and .labEmulationArtifacts[0].providerEmulationMode == "fake-provider"
  and .labEmulationArtifacts[0].scope == "harness"
  and .labEmulationArtifacts[0].handoffVlan == 11
  and .labEmulationArtifacts[0].liveUpstreamVlan == 4
  and .labEmulationArtifacts[0].liveUpstreamReachability.vlan == 4
  and .labEmulationArtifacts[0].dhcp4.address == "10.20.0.1/24"
  and .labEmulationArtifacts[0].dhcp4.rangeStart == "10.20.0.20"
  and .labEmulationArtifacts[0].dhcp4.rangeEnd == "10.20.0.99"
  and .labEmulationArtifacts[0].nat44.enabled == true
' "${tmp_dir}/lab-emulation/clab-bridge-plan.json" >/dev/null
grep -F 'would ensure Docker tooling image cache, cleanup fabric, materialize bridges, materialize lab emulation, deploy, and verify containers' \
  "${tmp_dir}/lab-emulation-dry-run.log" >/dev/null

echo "PASS deploy-clab-app-contract"
