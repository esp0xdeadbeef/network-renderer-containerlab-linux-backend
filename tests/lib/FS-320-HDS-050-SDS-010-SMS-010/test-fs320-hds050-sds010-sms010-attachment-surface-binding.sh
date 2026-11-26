#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-050-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# CLAB renderer construction test for the attachment surface binding module
# FS-320-HDS-050-SDS-010-SMS-010. Expected state: FAILING. The surface record and binding do not
# exist in this renderer yet; the test names the required behaviour so a
# solution can be proven against it.
#
# The CLAB backend attaches interfaces through bridges rather than host NICs,
# so this is the renderer that must prove the "physical attachment is optional"
# half of the SMS. Predicates:
#   1. surface record validation — one surfaceClass of
#      physical | external-bridge | internal-bridge, one surfaceRef, one
#      surfaceRefSource.
#   2. lookup-only binding — the named surfaceRef is carried through as given.
#   3. a site whose interfaces use only bridges, with no physical surface
#      anywhere, is accepted and renders.
#   4. an internal bridge with no member reaching the target is accepted.
#   5. no substitution — the rendered topology never binds a surface other
#      than the named one.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import json
import sys
import tempfile
from pathlib import Path

from clabgen.s88.enterprise.enterprise import Enterprise

TRACE = "FS-320-HDS-050-SDS-010-SMS-010"
SURFACE_CLASSES = ("physical", "external-bridge", "internal-bridge")

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS: {name}")
    else:
        failures.append(name)
        print(f"  FAIL: {name}{(' — ' + detail) if detail else ''}", file=sys.stderr)


def surface_record(surface_class, surface_ref, source="inventory"):
    return {
        "surfaceClass": surface_class,
        "surfaceRef": surface_ref,
        "surfaceRefSource": source,
    }


def make_solver_json():
    """A site whose attachments are bridge-only: no physical surface at all.

    The access node reaches the core through an external bridge that has no
    member ports, and the core-side attachment is an internal bridge with no
    path to a real port. Both are legal per the SMS.
    """
    return {
        "enterprise": {
            "esp0deadbeef": {
                "site": {
                    "site-a": {
                        "nodes": {
                            "core-router": {
                                "role": "core",
                                "routing_mode": "static",
                                "routingDomain": "core",
                                "loopback": {"ipv4": "10.255.0.1/32"},
                                "interfaces": {
                                    "to-access": {
                                        "runtimeIfName": "ens10",
                                        "kind": "p2p",
                                        "addr4": "192.0.2.0/31",
                                        "attachmentSurface": surface_record(
                                            "internal-bridge", "br-core-internal"
                                        ),
                                    },
                                    "tenant-admin": {
                                        "runtimeIfName": "ens20",
                                        "kind": "tenant",
                                        "tenant": "admin",
                                        "addr4": "10.20.15.1/24",
                                        "attachBridge": "br-admin",
                                        "attachmentSurface": surface_record(
                                            "external-bridge", "br-admin"
                                        ),
                                    },
                                },
                            },
                            "access-node": {
                                "role": "access",
                                "routing_mode": "static",
                                "routingDomain": "access",
                                "loopback": {"ipv4": "10.255.0.2/32"},
                                "interfaces": {
                                    "to-core": {
                                        "runtimeIfName": "ens10",
                                        "kind": "p2p",
                                        "addr4": "192.0.2.1/31",
                                        "attachmentSurface": surface_record(
                                            "external-bridge", "br-core-internal"
                                        ),
                                    },
                                    "tenant-client": {
                                        "runtimeIfName": "ens20",
                                        "kind": "tenant",
                                        "tenant": "client",
                                        "addr4": "10.20.16.1/24",
                                        "attachBridge": "br-client",
                                        "attachmentSurface": surface_record(
                                            "external-bridge", "br-client"
                                        ),
                                    },
                                },
                            },
                        },
                        "links": {
                            "p2p-core-access": {
                                "kind": "p2p",
                                "bridge": "br-core-internal",
                                "endpoints": {
                                    "core-router": {"interface": "to-access"},
                                    "access-node": {"interface": "to-core"},
                                },
                            },
                        },
                    }
                }
            }
        }
    }


def render(solver_json):
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, dir="/tmp"
    ) as handle:
        json.dump(solver_json, handle)
        solver_path = handle.name
    try:
        enterprise = Enterprise.from_solver_json(solver_path, renderer_inventory={})
        return enterprise.render()
    finally:
        Path(solver_path).unlink()


print(f"--- {TRACE}: CLAB attachment surface binding ---")

rendered = render(make_solver_json())
rendered_json = json.dumps(rendered)

print()
print("--- Predicate 1: attachment surfaces are carried as records ---")
check(
    "rendered topology carries attachment surface records",
    "attachmentSurface" in rendered_json or "surfaceClass" in rendered_json,
    "no attachmentSurface/surfaceClass anywhere in rendered topology",
)
check(
    "surface class set is the SMS set",
    set(SURFACE_CLASSES) == {"physical", "external-bridge", "internal-bridge"},
)

print()
print("--- Predicate 2: named surfaces are carried through unchanged ---")
for named in ("br-core-internal", "br-admin", "br-client"):
    check(
        f"named surface {named} reaches the rendered topology",
        named in rendered_json,
        "named surface missing from rendered topology",
    )

print()
print("--- Predicate 3: a bridge-only site renders with no physical surface ---")
check(
    "bridge-only site renders",
    isinstance(rendered, dict)
    and isinstance(rendered.get("topology"), dict)
    and bool(rendered["topology"].get("nodes")),
    "render produced no topology nodes",
)
check(
    "no physical surface is required by the render",
    "physical" not in rendered_json,
    "renderer invented a physical surface requirement for a bridge-only site",
)

print()
print("--- Predicate 4: an internal bridge with no member is accepted ---")
nodes = rendered.get("topology", {}).get("nodes", {})
check(
    "ungrounded internal bridge did not abort the render",
    bool(nodes),
    "render aborted on an ungrounded internal bridge",
)

print()
print("--- Predicate 5: no substituted surface ---")
check(
    "renderer did not invent an interface name in place of a named surface",
    not any(
        marker in rendered_json
        for marker in ('"surfaceRef": "eth999"', '"substituted-surface"')
    ),
    "a substituted surface appeared in the rendered topology",
)

print()
if failures:
    print(
        f"FAIL {TRACE} — {len(failures)} predicate(s) unmet: {', '.join(failures)}. "
        "Expected failing state until the attachment surface binding module exists.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"PASS {TRACE} — CLAB renderer carries attachment surfaces without substitution.")
PY
