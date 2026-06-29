#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-010-SMS-010
# GAMP-SCOPE: software-integration-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.models import SiteModel
from clabgen.s88.site.bridge_networks import renderer_bridge_networks


def site_with(containerlab):
    return SiteModel(
        enterprise="esp",
        site="clab",
        nodes={},
        links={},
        single_access="",
        domains={},
        renderer_inventory={
            "containerlab": containerlab,
            "deployment": {
                "hosts": {
                    "s-router-clab": {
                        "uplinks": {
                            "wan": {
                                "bridge": "br-clab-wan",
                                "mode": "native",
                                "parent": "ens4",
                                "upstream": "wan",
                            }
                        }
                    },
                    "s-router-hetz": {
                        "uplinks": {
                            "inter-site": {
                                "bridge": "br-wan",
                                "mode": "native",
                                "parent": "enp1s0",
                                "upstream": "inter-site",
                            },
                            "management": {
                                "bridge": "br-wan",
                                "mode": "native",
                                "parent": "enp1s0",
                            },
                            "wan": {
                                "bridge": "br-wan",
                                "hostAddresses": ["172.31.254.1/24"],
                                "mode": "native",
                                "parent": "enp1s0",
                                "upstream": "wan",
                            },
                        }
                    },
                }
            },
        },
    )


scoped = renderer_bridge_networks(site_with({"targetHost": "s-router-clab"}))
if sorted(scoped) != ["br-clab-wan"]:
    raise AssertionError(f"target host bridge scope leaked unrelated hosts: {scoped!r}")
if scoped["br-clab-wan"].get("parent") != "ens4":
    raise AssertionError(f"target host bridge data was not preserved: {scoped!r}")

try:
    renderer_bridge_networks(site_with({}))
except ValueError as exc:
    if "multiple bridge network definitions render to 'br-wan'" not in str(exc):
        raise
else:
    raise AssertionError("unscoped bridge derivation must still reject duplicates")

print("PASS target-host-bridge-scope")
PY
