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
    # FS-310-HDS-040-SDS-010-SMS-102 (CLAB renderer canonical-only consumption):
    # the renderer may map the canonical collections and nothing else. A released
    # bundle still CARRIES the producer artifact at `network.data` -- identity and
    # coverage are computed over it -- and this renderer used to read it, building
    # its own solver model from `control_plane_model.data.<enterprise>.<site>`.
    # That is the boundary violation, so the gate refuses the artifact outright
    # rather than letting a renderer that has not been repaired render anything.
    #
    # Fail fast, and say what to map instead: a payload carrying `network` cannot
    # be rendered by this backend until `cpm_solver` reads `canonical.*`.
    if "network" in bundle:
        raise _redacted(
            "FS-310-HDS-040-SDS-010-SMS-102: the renderer input carries 'network' (the "
            "plain control-plane artifact). The CLAB backend may map only the bundle's "
            "'canonical' collections; building the solver model from "
            "control_plane_model.data is the violation this row forbids. Serialise "
            "validateRendererInput.rendererInput (canonical collections + stamps, no "
            "'network' key) and map canonical.canonicalSites / canonicalRuntimeTargets / "
            "canonicalInterfaces / canonicalRoutes"
        )
    network = bundle.get("network")
    if not isinstance(network, dict) or not isinstance(network.get("data"), dict):
        raise _redacted("bundle does not carry network data")
    data = network["data"]
    # Two producer shapes reach a renderer: the semantic model itself
    # (`{data: <enterprise map>, ...}`) and the control-plane envelope the real
    # pipeline carries (`{control_plane_model: <model>, ...}`). Return ONE
    # envelope shape so callers never wrap it a second time.
    control_plane_model = data.get("control_plane_model")
    envelope = (
        data
        if isinstance(control_plane_model, dict)
        else {"control_plane_model": data}
    )
    if not isinstance(envelope["control_plane_model"].get("data"), dict):
        raise _redacted("bundle does not carry control-plane model data")
    return envelope


__all__ = [
    "BUNDLE_KIND",
    "DIRECT_CPM_CODE",
    "CanonicalInputError",
    "control_plane_envelope",
    "is_direct_cpm",
]
