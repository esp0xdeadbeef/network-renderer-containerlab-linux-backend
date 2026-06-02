#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.cpm_solver import control_plane_model_to_solver_json

cpm = {
    "control_plane_model": {
        "version": 1,
        "data": {
            "esp": {
                "clab": {
                    "runtimeTargets": {
                        "access-runtime": {
                            "role": "access",
                            "routingMode": "static",
                            "logicalNode": {
                                "enterprise": "esp",
                                "site": "clab",
                                "name": "access-client",
                            },
                            "advertisements": {
                                "dhcp4": [
                                    {
                                        "id": "client",
                                        "interface": "tenant-client",
                                        "subnet": "10.50.20.0/24",
                                        "pool": {
                                            "start": "10.50.20.100",
                                            "end": "10.50.20.199",
                                        },
                                        "reservations": [
                                            {
                                                "mac": "02:50:20:00:00:10",
                                                "hostOffset": 10,
                                                "address": "10.50.20.10",
                                                "cidr": "10.50.20.10/32",
                                            }
                                        ],
                                    }
                                ],
                            },
                            "effectiveRuntimeRealization": {
                                "interfaces": {
                                    "tenant-client": {
                                        "sourceKind": "tenant",
                                        "runtimeIfName": "tenant-client",
                                        "addr4": "10.50.20.1/24",
                                        "backingRef": {
                                            "kind": "attachment",
                                            "name": "client",
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

try:
    control_plane_model_to_solver_json(cpm)
except ValueError as exc:
    message = str(exc)
    assert "containerlab-linux renderer does not materialize DHCP reservations" in message
    assert "runtimeTargets.access-runtime.advertisements" in message
else:
    raise SystemExit("FAIL dhcp-reservation-contract-fail-closed: unsupported reservations were accepted")

print("PASS dhcp-reservation-contract-fail-closed")
PY
