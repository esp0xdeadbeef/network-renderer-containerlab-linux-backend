#!/usr/bin/env bash
# GAMP-ID: FS-500-HDS-010-SDS-010-SMS-040
# Construction test: CLAB route materialization artifact for p2p same-link checks.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmpdir="$(mktemp -d "${TMPDIR:-/var/tmp}/clab-route-materialization.XXXXXX")"
trap 'rm -rf "${tmpdir}"' EXIT

fixture="${tmpdir}/cpm.json"
output="${tmpdir}/clab-route-materialization.json"

cat >"${fixture}" <<'JSON'
{
  "network": {
    "data": {
      "canonicalRoutes": [
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "p2p-ab",
          "runtimeIfName": "ab0",
          "sourceKind": "p2p",
          "policyOnly": false,
          "family": 4,
          "dst": "10.111.0.0/24",
          "gateway": "10.11.0.1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "p2p-ab",
          "runtimeIfName": "ab0",
          "sourceKind": "p2p",
          "policyOnly": false,
          "family": 4,
          "dst": "10.112.0.0/24",
          "gateway": "10.11.0.1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "p2p-ab",
          "runtimeIfName": "ab0",
          "sourceKind": "p2p",
          "policyOnly": true,
          "family": 4,
          "dst": "10.113.0.0/24",
          "gateway": "10.11.0.1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "p2p-ab",
          "runtimeIfName": "ab0",
          "sourceKind": "p2p",
          "policyOnly": false,
          "family": 6,
          "dst": "fd11:111::/64",
          "gateway": "fd11::1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "p2p-ab",
          "runtimeIfName": "ab0",
          "sourceKind": "p2p",
          "policyOnly": true,
          "family": 6,
          "dst": "fd11:112::/64",
          "gateway": "fd11::1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-clab-router-a",
          "interface": "lan-client",
          "runtimeIfName": "lan0",
          "sourceKind": "lan",
          "policyOnly": false,
          "family": 4,
          "dst": "10.200.0.0/24",
          "gateway": "10.200.0.1",
          "tableId": null,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-clab"
        },
        {
          "target": "esp0xdeadbeef-site-b-nixos-router",
          "interface": "p2p-off-host",
          "runtimeIfName": "off0",
          "sourceKind": "p2p",
          "policyOnly": false,
          "family": 4,
          "dst": "10.250.0.0/24",
          "gateway": "10.250.0.1",
          "tableId": 1002,
          "metric": null,
          "kind": "internal-reachability",
          "deploymentHost": "s-router-nixos"
        }
      ]
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
bundle_work_copy = 'cp "$bootstrap_json" "$work_dir/canonical-bundle.json"'
bundle_artifact_copy = 'cp "$bootstrap_json" "$artifact_dir/canonical-bundle.json"'
route_projection = 'canonical-routes.json'
inventory_copy = 'cp "$renderer_inventory_json" "$artifact_dir/inventory.json"'
route_artifact = "clabgen.s88.CM.route_materialization_artifact"
# FS-310-HDS-040-SDS-010-SMS-100: the host publishes the released canonical
# bundle. A raw CPM payload (and its compiler/forwarding internals) is not a
# renderer artifact and must not be copied or republished.
assert bundle_work_copy in host_module, "host module must materialize the released canonical bundle"
assert bundle_artifact_copy in host_module, "host module must publish the released canonical bundle artifact"
assert route_projection in host_module, "host module must derive the route projection from the released bundle"
assert 'cp "$cpm_json"' not in host_module, "host module must not publish a raw CPM payload"
assert ".forwardingOut" not in host_module, "CPM forwarding internals are not renderer artifacts"
assert ".compilerOut" not in host_module, "CPM compiler internals are not renderer artifacts"
assert inventory_copy in host_module, "host module must publish current renderer inventory artifact"
assert host_module.index(bundle_artifact_copy) < host_module.index(route_artifact), host_module
assert host_module.index(route_projection) < host_module.index(route_artifact), host_module
PY

echo "PASS FS-500-HDS-010-SDS-010-SMS-040 clab-route-materialization-artifact"
