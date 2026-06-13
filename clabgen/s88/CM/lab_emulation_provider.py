from __future__ import annotations

from typing import Any, Dict

from clabgen.s88.CM.lab_emulation_schema import (
    FAKE_PROVIDER_CLIENT_SIDE_VLAN,
    FAKE_PROVIDER_HANDOFF_VLAN,
    RESERVED_FAKE_PROVIDER_VLANS,
)


def _vlan_from_request(
    request: Dict[str, Any], direct_key: str, object_key: str
) -> Any:
    if direct_key in request:
        return request.get(direct_key)
    nested = request.get(object_key)
    if isinstance(nested, dict):
        return nested.get("vlan")
    return None


def _require_positive_vlan(value: Any, field_name: str, mode: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{mode} lab-emulation request requires positive {field_name}")
    return value


def _optional_vlan(
    request: Dict[str, Any],
    direct_key: str,
    object_key: str,
    mode: str,
) -> int | None:
    raw_value = _vlan_from_request(request, direct_key, object_key)
    if raw_value is None:
        return None
    # FS-310-HDS-010-SDS-010-SMS-110: fail-closed — must use
    # providerEmulationMode from the resolved mode parameter,
    # not a multi-key fallback chain
    if not isinstance(mode, str) or not mode:
        raise ValueError(
            "lab-emulation request requires providerEmulationMode; "
            "multi-key fallback defaults are not allowed"
        )
    return _require_positive_vlan(raw_value, object_key, mode)


def _ensure_not_reserved(vlan: int, field_name: str, mode: str) -> None:
    if vlan in RESERVED_FAKE_PROVIDER_VLANS:
        raise ValueError(
            f"{mode} lab-emulation request cannot use reserved "
            f"fake-provider VLAN {vlan} for {field_name}"
        )


def _optional_exchange_object(
    request: Dict[str, Any],
    key: str,
    label: str,
    mode: str,
) -> Dict[str, Any] | None:
    value = request.get(key)
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError(
            f"{mode} lab-emulation request requires {label} to be an object"
        )
    return dict(value)


def _harness_scope(request: Dict[str, Any], mode: str) -> None:
    scope = request.get("scope") or "harness"
    if scope != "harness":
        raise ValueError(
            f"{mode} lab-emulation request must be harness-scoped, got {scope!r}"
        )


def _handoff_vlan(request: Dict[str, Any], mode: str) -> int:
    handoff_vlan = _require_positive_vlan(
        _vlan_from_request(request, "handoffVlan", "providerToCoreHandoff"),
        "provider-to-core handoff VLAN",
        mode,
    )
    if handoff_vlan != FAKE_PROVIDER_HANDOFF_VLAN:
        raise ValueError(
            f"{mode} lab-emulation request requires provider-to-core "
            f"handoff VLAN {FAKE_PROVIDER_HANDOFF_VLAN}"
        )
    return handoff_vlan


def _live_upstream_vlan(
    request: Dict[str, Any],
    mode: str,
    handoff_vlan: int,
) -> int | None:
    raw_value = _vlan_from_request(
        request,
        "liveUpstreamVlan",
        "liveUpstreamReachability",
    )
    if raw_value is None:
        return None
    live_upstream_vlan = _require_positive_vlan(
        raw_value,
        "live upstream reachability VLAN",
        mode,
    )
    if live_upstream_vlan == handoff_vlan:
        raise ValueError(
            f"{mode} lab-emulation request must keep provider-to-core handoff "
            "VLAN separate from live upstream reachability VLAN"
        )
    _ensure_not_reserved(live_upstream_vlan, "live upstream reachability", mode)
    return live_upstream_vlan


def _client_side_vlan(
    request: Dict[str, Any],
    mode: str,
    handoff_vlan: int,
    live_upstream_vlan: int | None,
) -> int | None:
    client_side_vlan = _optional_vlan(
        request,
        "clientSideVlan",
        "isolatedClientSide",
        mode,
    )
    if client_side_vlan is None:
        return None
    if client_side_vlan != FAKE_PROVIDER_CLIENT_SIDE_VLAN:
        raise ValueError(
            f"{mode} lab-emulation request requires isolated client-side "
            f"VLAN {FAKE_PROVIDER_CLIENT_SIDE_VLAN} when client-side "
            "substrate is modeled"
        )
    if client_side_vlan == handoff_vlan or client_side_vlan == live_upstream_vlan:
        raise ValueError(
            f"{mode} lab-emulation request must keep isolated client-side VLAN "
            "separate from handoff and live upstream VLANs"
        )
    return client_side_vlan


def _copy_optional_exchange_objects(
    artifact: Dict[str, Any],
    request: Dict[str, Any],
    mode: str,
) -> None:
    for key, label in (
        ("delegatedPrefixAuthority", "delegated prefix authority"),
        ("nat44Selection", "NAT44 selection"),
        ("nat66Selection", "NAT66 selection"),
        ("routerGuaDenial", "router-GUA denial"),
    ):
        value = _optional_exchange_object(request, key, label, mode)
        if value is not None:
            artifact[key] = value


def provider_emulation_artifact(
    request: Dict[str, Any],
    mode: str,
) -> Dict[str, Any]:
    _harness_scope(request, mode)
    handoff_vlan = _handoff_vlan(request, mode)
    live_upstream_vlan = _live_upstream_vlan(request, mode, handoff_vlan)
    client_side_vlan = _client_side_vlan(
        request,
        mode,
        handoff_vlan,
        live_upstream_vlan,
    )

    artifact = dict(request)
    artifact["providerEmulationMode"] = mode
    artifact["scope"] = "harness"
    artifact["harnessScoped"] = True
    artifact["ordinaryTargetOutput"] = False
    artifact["providerToCoreHandoff"] = {"vlan": handoff_vlan}
    if live_upstream_vlan is not None:
        artifact["liveUpstreamReachability"] = {"vlan": live_upstream_vlan}
    if client_side_vlan is not None:
        artifact["isolatedClientSide"] = {"vlan": client_side_vlan}
    _copy_optional_exchange_objects(artifact, request, mode)
    return artifact
