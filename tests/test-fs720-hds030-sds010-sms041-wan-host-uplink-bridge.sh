#!/usr/bin/env bash
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-041
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-041-CMC
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

TMP_DIR="${tmp_dir}" PYTHONPATH="${repo_root}" python3 - <<'PY'
from pathlib import Path
import json
import os

from clabgen.s88.enterprise.enterprise import Enterprise

tmp = Path(os.environ["TMP_DIR"])

cpm = {
    "control_plane_model": {
        "version": 1,
        "data": {
            "mini-smt": {
                "internet-mode-verification": {
                    "runtimeTargets": {
                        "mini-smt-internet-mode-verification-emulated-isp": {
                            "role": "core",
                            "routingMode": "static",
                            "routingDomain": "internet",
                            "logicalNode": {
                                "enterprise": "mini-smt",
                                "site": "internet-mode-verification",
                                "name": "emulated-isp",
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "internet-vlan4": {
                                        "sourceKind": "wan",
                                        "runtimeIfName": "eth1",
                                        "upstream": "internet-vlan4",
                                        "backingRef": {"name": "internet-vlan4"},
                                        "hostUplink": {
                                            "bridge": "internet-vlan4",
                                            "ipv4": {"method": "dhcp"},
                                        },
                                    }
                                }
                            },
                        }
                    }
                }
            }
        },
    }
}

cpm_path = tmp / "cpm.json"
cpm_path.write_text(json.dumps(cpm))

rendered = Enterprise.from_solver_json(cpm_path, renderer_inventory={}).render()
links = rendered["topology"]["links"]
if len(links) != 1:
    raise AssertionError(f"expected one rendered WAN link, got {links!r}")

link = links[0]
labels = link.get("labels", {})
if labels.get("clab.link.bridge") != "internet-vlan4":
    raise AssertionError(f"WAN link did not use hostUplink.bridge: {link!r}")
if labels.get("clab.source.link") != "wan-emulated-isp-internet-vlan4":
    raise AssertionError(f"WAN source link was not preserved: {link!r}")
endpoints = link.get("endpoints")
if not isinstance(endpoints, list):
    raise AssertionError(f"WAN link endpoints were not rendered as a list: {link!r}")
if "mini-smt-internet-mode-verification-emulated-isp:eth1" not in endpoints:
    raise AssertionError(f"WAN link did not use CPM runtimeIfName: {link!r}")
if not any(endpoint.startswith("host:") for endpoint in endpoints):
    raise AssertionError(f"WAN bridge link did not include host endpoint: {link!r}")

missing_bridge = json.loads(json.dumps(cpm))
del missing_bridge["control_plane_model"]["data"]["mini-smt"][
    "internet-mode-verification"
]["runtimeTargets"]["mini-smt-internet-mode-verification-emulated-isp"][
    "effectiveRuntimeRealization"
]["interfaces"]["internet-vlan4"]["hostUplink"]["bridge"]
missing_path = tmp / "missing-bridge.json"
missing_path.write_text(json.dumps(missing_bridge))

try:
    Enterprise.from_solver_json(missing_path, renderer_inventory={}).render()
except ValueError as exc:
    if "MISSING_CPM_BRIDGE_FIELD" not in str(exc):
        raise AssertionError(f"unexpected missing-bridge diagnostic: {exc!r}") from exc
else:
    raise AssertionError("renderer accepted WAN link with no explicit bridge")

print("PASS wan-host-uplink-bridge-contract")
PY
