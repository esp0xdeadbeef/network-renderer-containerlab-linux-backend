"""Canonical renderer-input gate.

FS-310-HDS-040-SDS-010-SMS-100 (renderer canonical-only consumption) and FS-171
(single writer, consumers import): every ``network-renderer-*`` module receives
network-semantic input only as one validated canonical realization bundle
produced by ``network-realization-model`` under the pinned
``network-realization-schema`` contract. CPM output is upstream authority for
``network-realization-model``; it is not a public renderer input, and a raw CPM
payload must be rejected rather than silently rendered.
"""

from __future__ import annotations

from typing import Any, Dict

BUNDLE_KIND = "network-realization-bundle"
DIRECT_CPM_CODE = "GAMP-MODEL-BOUNDARY-VIOLATION"


class CanonicalInputError(ValueError):
    """A renderer input failed the canonical-bundle boundary."""


def _redacted(reason: str) -> CanonicalInputError:
    # Diagnostics never carry address material (FS-340 redaction).
    return CanonicalInputError(f"{DIRECT_CPM_CODE}: {reason}; address material is intentionally omitted")


def is_direct_cpm(payload: Any) -> bool:
    """True for a raw CPM payload that is not wrapped in a canonical bundle."""
    return (
        isinstance(payload, dict)
        and isinstance(payload.get("control_plane_model"), dict)
        and not isinstance(payload.get("network"), dict)
    )


def control_plane_envelope(bundle: Any) -> Dict[str, Any]:
    """Return the canonical control-plane envelope carried by a released bundle."""
    if is_direct_cpm(bundle):
        raise _redacted(
            "renderer input is a raw control-plane-model payload; renderers consume "
            "only a validated canonical realization bundle (FS-310-HDS-040-SDS-010-SMS-100)"
        )
    if not isinstance(bundle, dict):
        raise _redacted("renderer input must be a canonical realization bundle object")
    if bundle.get("kind") != BUNDLE_KIND:
        raise _redacted(
            f"renderer input kind is {bundle.get('kind')!r}, expected {BUNDLE_KIND!r}"
        )
    validation = bundle.get("validation")
    if not isinstance(validation, dict) or validation.get("valid") is not True:
        raise _redacted("bundle lacks the schema- and digest-bound release validation")
    identity = bundle.get("bundleIdentity")
    if not isinstance(identity, str) or not identity:
        raise _redacted("bundle lacks a bundle identity")
    if validation.get("artifactIdentity") != identity:
        raise _redacted("released identity does not match the supplied bundle content")
    network = bundle.get("network")
    if not isinstance(network, dict) or not isinstance(network.get("data"), dict):
        raise _redacted("bundle does not carry network data")
    return network["data"]


__all__ = [
    "BUNDLE_KIND",
    "DIRECT_CPM_CODE",
    "CanonicalInputError",
    "control_plane_envelope",
    "is_direct_cpm",
]
