from __future__ import annotations

from typing import Any, Dict


SUPPORTED_PROVIDER_EMULATION_MODES = {
    "fake-provider": "fake-provider",
    "fake_provider": "fake-provider",
    "fakeProvider": "fake-provider",
    "pppoe-like": "pppoe-like",
    "pppoe_like": "pppoe-like",
    "pppoeLike": "pppoe-like",
    "pppoe": "pppoe-like",
}
FAKE_PROVIDER_HANDOFF_VLAN = 11
FAKE_PROVIDER_CLIENT_SIDE_VLAN = 12
RESERVED_FAKE_PROVIDER_VLANS = set(range(13, 21))


def provider_emulation_mode(request: Dict[str, Any]) -> str:
    raw_mode = (
        request.get("providerEmulationMode")
        or request.get("mode")
        or request.get("kind")
        or request.get("type")
    )
    if not isinstance(raw_mode, str) or not raw_mode:
        raise ValueError(
            "structured refusal: lab-emulation request missing provider-emulation mode"
        )
    if raw_mode not in SUPPORTED_PROVIDER_EMULATION_MODES:
        raise ValueError(
            f"structured refusal: unsupported lab-emulation provider mode: {raw_mode!r}"
        )
    return SUPPORTED_PROVIDER_EMULATION_MODES[raw_mode]
