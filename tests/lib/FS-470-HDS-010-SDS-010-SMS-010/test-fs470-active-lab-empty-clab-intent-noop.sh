#!/usr/bin/env bash
# GAMP-ID: FS-470-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: active-lab SIT support; explicit empty CLAB renderer input must no-op, not fail the host service.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import json
import tempfile
from pathlib import Path

from clabgen.s88.enterprise.site_loader import load_sites


def write_payload(payload):
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    try:
        json.dump(payload, tmp)
        tmp.close()
        return Path(tmp.name)
    except Exception:
        tmp.close()
        Path(tmp.name).unlink(missing_ok=True)
        raise


renderer_inventory = {
    "containerlab": {"targetHost": "s-router-clab"},
    "realization": {"nodes": {}},
}

empty_payload = {
    "control_plane_model": {
        "meta": {"traceId": "active-lab-clab-no-runtime"},
        "data": {
            "active-lab": {
                "clab": {
                    "runtimeTargets": {},
                },
            },
        },
    },
}

non_empty_payload = {
    "control_plane_model": {
        "meta": {"traceId": "non-empty-target-host-negative"},
        "data": {
            "active-lab": {
                "clab": {
                    "runtimeTargets": {
                        "edge": {
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "active-lab",
                                "site": "clab",
                                "name": "edge",
                            },
                        },
                    },
                },
            },
        },
    },
}

paths = [write_payload(empty_payload), write_payload(non_empty_payload)]
try:
    empty_sites = load_sites(paths[0], renderer_inventory=renderer_inventory)
    if empty_sites != {}:
        raise SystemExit(
            f"FAIL empty CLAB active-lab intent should render no sites, got {empty_sites!r}"
        )

    try:
        load_sites(paths[1], renderer_inventory=renderer_inventory)
    except ValueError as exc:
        if "matched zero inventory realization nodes" not in str(exc):
            raise
    else:
        raise SystemExit(
            "FAIL non-empty target-host CPM without matching inventory nodes must fail closed"
        )
finally:
    for path in paths:
        path.unlink(missing_ok=True)

print("PASS fs470-active-lab-empty-clab-intent-noop")
PY
