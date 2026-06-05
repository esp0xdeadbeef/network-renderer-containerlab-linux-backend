#!/usr/bin/env bash
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-050
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY' "${repo_root}"
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path

repo = Path(sys.argv[1])
module_path = repo / "clabgen" / "parse-solver-json.py"
spec = importlib.util.spec_from_file_location("parse_solver_json", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None

sys.modules["yaml"] = types.SimpleNamespace(
    safe_dump=lambda payload, **_kwargs: json.dumps(payload)
)

spec.loader.exec_module(module)

payload = {
    "control_plane_model": {
        "version": 1,
        "meta": {
            "sourceClasses": {
                "userIntent": {
                    "path": "examples/fs100/intent.nix",
                    "narHash": "sha256-intent",
                },
                "publicInventory": {
                    "path": "examples/fs100/inventory-clab.nix",
                    "narHash": "sha256-public-inventory",
                },
                "protectedInventory": {
                    "ref": "sops://examples/fs100/protected.yaml",
                    "secretValue": "PLAINTEXT-PROTECTED-VALUE",
                },
                "runtimeFacts": {
                    "ref": "runtime://provider/public-addresses",
                },
                "validationContext": {
                    "profile": "renderer-construction",
                },
            },
            "requested": {
                "scope": {
                    "site": "clab",
                    "host": "s-router-clab",
                },
                "target": {
                    "renderer": "containerlab-linux",
                    "role": "renderer-output",
                },
            },
            "locks": {
                "network-control-plane-model": {
                    "rev": "1111222233334444555566667777888899990000",
                    "narHash": "sha256-cpm",
                }
            },
            "controlledBaseline": "fs100-renderer-output-provenance",
        },
        "data": {
            "esp": {
                "clab": {
                    "runtimeTargets": {
                        "access-runtime": {
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp",
                                "site": "clab",
                                "name": "access",
                            },
                        }
                    }
                }
            }
        },
    }
}

def fake_render_topology(_path, **_kwargs):
    return {
        "name": "fabric",
        "topology": {"nodes": {}, "links": []},
        "bridges": [],
        "bridge_networks": {},
    }

def fake_load_solver(_path):
    return {}

module.render_topology = fake_render_topology
module.load_solver = fake_load_solver

with tempfile.TemporaryDirectory() as tmp:
    tmp_dir = Path(tmp)
    cpm_path = tmp_dir / "cpm.json"
    topology_path = tmp_dir / "fabric.clab.yml"
    bridges_path = tmp_dir / "vm-bridges-generated.nix"
    cpm_path.write_text(json.dumps(payload), encoding="utf-8")

    module.write_outputs(cpm_path, topology_path, bridges_path)
    rendered = topology_path.read_text(encoding="utf-8")

    if "PLAINTEXT-PROTECTED-VALUE" in rendered:
        raise SystemExit("FAIL fs100-renderer-output-provenance: protected value leaked")
    if "<redacted>" not in rendered:
        raise SystemExit("FAIL fs100-renderer-output-provenance: redaction marker missing")

    lines = rendered.splitlines()
    start = lines.index("# --- provenance ---") + 1
    end = lines.index("# --- end provenance ---")
    provenance_json = "\n".join(line[2:] for line in lines[start:end])
    provenance = json.loads(provenance_json)

    source_classes = provenance["sources"]["sourceClasses"]
    assert source_classes["userIntent"]["path"] == "examples/fs100/intent.nix"
    assert source_classes["publicInventory"]["path"] == "examples/fs100/inventory-clab.nix"
    assert source_classes["protectedInventory"]["secretValue"] == "<redacted>"
    assert source_classes["runtimeFacts"]["ref"] == "runtime://provider/public-addresses"
    assert source_classes["validationContext"]["profile"] == "renderer-construction"

    assert provenance["requested"]["scope"]["site"] == "clab"
    assert provenance["requested"]["target"]["renderer"] == "containerlab-linux"
    assert provenance["requested"]["derivedScope"]["sites"] == ["esp/clab"]
    assert (
        provenance["requested"]["derivedScope"]["runtimeTargets"]
        == ["esp/clab/access-runtime"]
    )
    assert (
        provenance["locks"]["upstream"]["network-control-plane-model"]["rev"]
        == "1111222233334444555566667777888899990000"
    )
    assert provenance["locks"]["renderer"]["available"] is True
    assert provenance["output"]["kind"] == "containerlab-topology"
    assert provenance["controlledBaseline"] == "fs100-renderer-output-provenance"

print("PASS fs100-renderer-output-provenance")
PY
