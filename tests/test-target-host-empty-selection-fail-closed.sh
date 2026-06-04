#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clab-empty-target.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/cpm.json" <<'JSON'
{
  "control_plane_model": {
    "data": {
      "esp": {
        "site-a": {
          "runtimeTargets": {
            "esp-site-a-router": {
              "routingMode": "static",
              "logicalNode": {
                "enterprise": "esp",
                "site": "site-a",
                "name": "router"
              }
            }
          },
          "nodes": {
            "router": {
              "role": "core"
            }
          },
          "links": {}
        }
      }
    }
  }
}
JSON

cat > "${tmp_dir}/inventory.json" <<'JSON'
{
  "containerlab": {
    "targetHost": "missing-host"
  },
  "realization": {
    "nodes": {
      "esp-site-a-router": {
        "host": "real-host",
        "logicalNode": {
          "enterprise": "esp",
          "site": "site-a",
          "name": "router"
        }
      }
    }
  }
}
JSON

if PYTHONPATH="${repo_root}" python3 - "${tmp_dir}/cpm.json" "${tmp_dir}/inventory.json" >"${tmp_dir}/out" 2>"${tmp_dir}/err" <<'PY'
import json
import sys

from clabgen.s88.enterprise.site_loader import load_sites

cpm_path = sys.argv[1]
inventory_path = sys.argv[2]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)

load_sites(cpm_path, renderer_inventory=inventory)
PY
then
  echo "FAIL target-host-empty-selection: renderer accepted a targetHost with zero realization nodes" >&2
  exit 1
fi

if ! grep -F "targetHost 'missing-host' matched zero inventory realization nodes" "${tmp_dir}/err" >/dev/null; then
  echo "FAIL target-host-empty-selection: missing diagnostic" >&2
  cat "${tmp_dir}/err" >&2 || true
  exit 1
fi

echo "PASS target-host-empty-selection"
