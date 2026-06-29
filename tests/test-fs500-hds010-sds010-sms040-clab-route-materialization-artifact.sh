#!/usr/bin/env bash
# GAMP-ID: FS-500-HDS-010-SDS-010-SMS-040
# Construction test: CLAB route materialization artifact for p2p same-link checks.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d /tmp/clab-route-materialization.XXXXXX)"
trap 'rm -rf "${tmpdir}"' EXIT

fixture="${tmpdir}/cpm.json"
output="${tmpdir}/clab-route-materialization.json"

cat >"${fixture}" <<'JSON'
{
  "control_plane_model": {
    "data": {
      "esp": {
        "site-b": {
          "runtimeTargets": {
            "esp0xdeadbeef-site-b-clab-router-a": {
              "placement": {
                "host": "s-router-clab"
              },
              "logicalNode": {
                "name": "clab-router-a"
              },
              "effectiveRuntimeRealization": {
                "interfaces": {
                  "p2p-ab": {
                    "sourceKind": "p2p",
                    "runtimeIfName": "ab0",
                    "addr4": "10.11.0.0/31",
                    "addr6": "fd11::/127",
                    "routes": {
                      "ipv4": [
                        {
                          "dst": "10.111.0.0/24",
                          "via4": "10.11.0.1"
                        },
                        {
                          "destination": "10.112.0.0/24",
                          "via4": "10.11.0.1"
                        },
                        {
                          "dst": "10.113.0.0/24",
                          "via4": "10.11.0.1",
                          "policyOnly": true
                        },
                        {
                          "sourceFile": "/run/secrets/runtime-ipv4-prefix",
                          "via4": "10.11.0.1"
                        }
                      ],
                      "ipv6": [
                        {
                          "prefix": "fd11:111::/64",
                          "via6": "fd11::1"
                        },
                        {
                          "dst": "fd11:112::/64",
                          "via6": "fd11::1",
                          "policyOnly": true
                        },
                        {
                          "sourceFile": "/run/secrets/runtime-ipv6-prefix",
                          "via6": "fd11::1"
                        }
                      ]
                    }
                  },
                  "p2p-ab-alias": {
                    "sourceKind": "p2p",
                    "runtimeIfName": "ab0",
                    "routes": {
                      "ipv4": [
                        {
                          "dst": "10.111.0.0/24",
                          "via4": "10.11.0.1"
                        }
                      ]
                    }
                  },
                  "lan-client": {
                    "sourceKind": "lan",
                    "runtimeIfName": "lan0",
                    "routes": {
                      "ipv4": [
                        {
                          "dst": "10.200.0.0/24",
                          "via4": "10.200.0.1"
                        }
                      ]
                    }
                  }
                }
              }
            },
            "esp0xdeadbeef-site-b-clab-router-b": {
              "placement": {
                "host": "s-router-clab"
              },
              "logicalNode": {
                "name": "clab-router-b"
              },
              "effectiveRuntimeRealization": {
                "interfaces": {
                  "p2p-ba": {
                    "sourceKind": "p2p",
                    "runtimeIfName": "ba0",
                    "addr4": "10.11.0.1/31",
                    "routes": {
                      "ipv4": []
                    }
                  }
                }
              }
            },
            "esp0xdeadbeef-site-b-nixos-router": {
              "placement": {
                "host": "s-router-nixos"
              },
              "logicalNode": {
                "name": "nixos-router"
              },
              "effectiveRuntimeRealization": {
                "interfaces": {
                  "p2p-off-host": {
                    "sourceKind": "p2p",
                    "runtimeIfName": "off0",
                    "routes": {
                      "ipv4": [
                        {
                          "dst": "10.250.0.0/24",
                          "via4": "10.250.0.1"
                        }
                      ]
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
JSON

PYTHONPATH="${repo_root}" python3 -m clabgen.s88.CM.route_materialization_artifact \
  "${fixture}" \
  s-router-clab \
  "${output}"

python3 - "${output}" "${repo_root}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
repo = Path(sys.argv[2])
assert payload["artifactKind"] == "containerlab-route-materialization", payload
assert payload["renderer"] == "network-renderer-containerlab-linux-backend", payload
assert payload["deploymentHost"] == "s-router-clab", payload

routes = payload["routes"]
assert len(routes) == 3, routes
route_keys = {
    (
        route["runtimeTarget"],
        route["interfaceKey"],
        route["ifname"],
        route["family"],
        route["dst"],
        route.get("via4") or route.get("via6"),
    )
    for route in routes
}

assert (
    "esp0xdeadbeef-site-b-clab-router-a",
    "p2p-ab",
    "ab0",
    "ipv4",
    "10.111.0.0/24",
    "10.11.0.1",
) in route_keys, route_keys
assert (
    "esp0xdeadbeef-site-b-clab-router-a",
    "p2p-ab",
    "ab0",
    "ipv4",
    "10.112.0.0/24",
    "10.11.0.1",
) in route_keys, route_keys
assert (
    "esp0xdeadbeef-site-b-clab-router-a",
    "p2p-ab",
    "ab0",
    "ipv6",
    "fd11:111::/64",
    "fd11::1",
) in route_keys, route_keys

all_text = json.dumps(payload, sort_keys=True)
assert "runtime-ipv4-prefix" not in all_text, payload
assert "runtime-ipv6-prefix" not in all_text, payload
assert "10.113.0.0/24" not in all_text, payload
assert "fd11:112::/64" not in all_text, payload
assert "lan0" not in all_text, payload
assert "10.250.0.0/24" not in all_text, payload
assert all(route["source"] == "control-plane-model" for route in routes), routes

host_module = (repo / "host-module.nix").read_text()
control_plane_copy = 'cp "$cpm_json" "$artifact_dir/control-plane.json"'
cpm_copy = 'cp "$cpm_json" "$work_dir/cpm.json"'
inventory_copy = 'cp "$renderer_inventory_json" "$artifact_dir/inventory.json"'
route_artifact = "clabgen.s88.CM.route_materialization_artifact"
assert control_plane_copy in host_module, "host module must publish current CPM as control-plane artifact"
assert cpm_copy in host_module, "host module must publish current CPM as cpm.json"
assert inventory_copy in host_module, "host module must publish current renderer inventory artifact"
assert host_module.index(control_plane_copy) < host_module.index(route_artifact), host_module
PY

echo "PASS FS-500-HDS-010-SDS-010-SMS-040 clab-route-materialization-artifact"
