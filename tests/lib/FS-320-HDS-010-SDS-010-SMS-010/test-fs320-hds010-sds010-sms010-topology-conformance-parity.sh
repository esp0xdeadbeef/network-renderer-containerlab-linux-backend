#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-010
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

TMP_DIR="${tmp_dir}" PYTHONPATH="${repo_root}" python3 - <<'PY'
from pathlib import Path
import copy
import json
import os

from clabgen.s88.enterprise.enterprise import Enterprise

tmp = Path(os.environ["TMP_DIR"])

cpm = {
    "control_plane_model": {
        "version": 1,
        "data": {
            "esp": {
                "site-a": {
                    "runtimeTargets": {
                        "rt-left": {
                            "role": "core",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp",
                                "site": "site-a",
                                "name": "left",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "p2p": {
                                        "sourceKind": "p2p",
                                        "runtimeIfName": "left0",
                                        "addr4": "10.0.0.0/31",
                                        "backingRef": {"name": "p2p"},
                                        "attach": {"bridge": "br-p2p"},
                                    }
                                }
                            },
                        },
                        "rt-right": {
                            "role": "core",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp",
                                "site": "site-a",
                                "name": "right",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "p2p": {
                                        "sourceKind": "p2p",
                                        "runtimeIfName": "right0",
                                        "addr4": "10.0.0.1/31",
                                        "backingRef": {"name": "p2p"},
                                        "attach": {"bridge": "br-p2p"},
                                    }
                                }
                            },
                        },
                    },
                    "transit": {
                        "adjacencies": [
                            {
                                "link": "p2p",
                                "kind": "p2p",
                                "endpoints": [
                                    {"unit": "left"},
                                    {"unit": "right"},
                                ],
                            }
                        ]
                    },
                }
            }
        },
    }
}

cpm_path = tmp / "cpm.json"
inventory_path = tmp / "renderer-inventory.json"
good_topology_path = tmp / "fabric-good.clab.yml"
extra_node_path = tmp / "fabric-extra-node.clab.yml"
missing_link_path = tmp / "fabric-missing-link.clab.yml"
extra_link_path = tmp / "fabric-extra-link.clab.yml"

cpm_path.write_text(json.dumps(cpm))
inventory_path.write_text("{}")

def write_topology(path, topology):
    lines = [
        f"name: {topology['name']}",
        "topology:",
        "  defaults: {}",
        "  nodes:",
    ]
    for node_name in sorted(topology["topology"]["nodes"].keys()):
        node = topology["topology"]["nodes"][node_name]
        kind = "linux"
        if isinstance(node, dict) and isinstance(node.get("kind"), str):
            kind = node["kind"]
        lines.append(f"    {node_name}:")
        lines.append(f"      kind: {kind}")
    lines.append("  links:")
    for link in topology["topology"]["links"]:
        endpoints = link.get("endpoints") if isinstance(link, dict) else []
        if not isinstance(endpoints, list):
            continue
        lines.append("  - endpoints:")
        for endpoint in endpoints:
            lines.append(f"    - {endpoint}")
    path.write_text("\n".join(lines) + "\n")


rendered = Enterprise.from_solver_json(cpm_path, renderer_inventory={}).render()
good = {"name": rendered["name"], "topology": rendered["topology"]}
write_topology(good_topology_path, good)

extra_node = copy.deepcopy(good)
extra_node["topology"]["nodes"]["invented-node"] = {"kind": "linux"}
write_topology(extra_node_path, extra_node)

missing_link = copy.deepcopy(good)
missing_link["topology"]["links"] = []
write_topology(missing_link_path, missing_link)

extra_link = copy.deepcopy(good)
extra_link["topology"]["links"].append(
    {
        "endpoints": [
            "esp-site-a-left:left0",
            "invented-node:eth0",
        ]
    }
)
write_topology(extra_link_path, extra_link)
PY

"${repo_root}/tests/validate-topology-conformance.sh" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory.json" \
  "${tmp_dir}/fabric-good.clab.yml"

if "${repo_root}/tests/validate-topology-conformance.sh" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory.json" \
  "${tmp_dir}/fabric-extra-node.clab.yml" >"${tmp_dir}/extra-node.out" 2>"${tmp_dir}/extra-node.err"; then
  echo "FAIL topology-conformance-parity-guard: accepted extra rendered node" >&2
  exit 1
fi
grep -q "unexpected nodes" "${tmp_dir}/extra-node.err"

if "${repo_root}/tests/validate-topology-conformance.sh" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory.json" \
  "${tmp_dir}/fabric-missing-link.clab.yml" >"${tmp_dir}/missing-link.out" 2>"${tmp_dir}/missing-link.err"; then
  echo "FAIL topology-conformance-parity-guard: accepted missing rendered link" >&2
  exit 1
fi
grep -q "missing links" "${tmp_dir}/missing-link.err"

if "${repo_root}/tests/validate-topology-conformance.sh" \
  "${tmp_dir}/cpm.json" \
  "${tmp_dir}/renderer-inventory.json" \
  "${tmp_dir}/fabric-extra-link.clab.yml" >"${tmp_dir}/extra-link.out" 2>"${tmp_dir}/extra-link.err"; then
  echo "FAIL topology-conformance-parity-guard: accepted extra rendered link" >&2
  exit 1
fi
grep -q "unexpected nodes\\|extra links\\|unexpected links" "${tmp_dir}/extra-link.err"

echo "PASS topology-conformance-parity-guard"
