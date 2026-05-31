from __future__ import annotations

from typing import Any, Dict, List

from clabgen.models import SiteModel
from clabgen.s88.CM.lab_emulation_provider import provider_emulation_artifact
from clabgen.s88.CM.lab_emulation_schema import provider_emulation_mode


def _containerlab_inventory(site: SiteModel) -> Dict[str, Any]:
    renderer_inventory = site.renderer_inventory
    if not isinstance(renderer_inventory, dict):
        return {}
    containerlab = renderer_inventory.get("containerlab")
    return containerlab if isinstance(containerlab, dict) else {}


def _has_lab_emulation_capability(containerlab: Dict[str, Any]) -> bool:
    capabilities = containerlab.get("capabilities")
    if isinstance(capabilities, dict):
        for key in ("lab-emulation", "labEmulation"):
            if capabilities.get(key) is True:
                return True
    if isinstance(capabilities, list):
        for item in capabilities:
            if item in {"lab-emulation", "labEmulation"}:
                return True
        return False
    return containerlab.get("labEmulationCapability") is True


def _as_request_list(value: Any) -> List[Dict[str, Any]]:
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        items: List[Dict[str, Any]] = []
        for item in value:
            if isinstance(item, dict):
                items.append(item)
        return items
    return []


def _lab_emulation_requests(containerlab: Dict[str, Any]) -> List[Dict[str, Any]]:
    requests: List[Dict[str, Any]] = []

    lab_emulation = containerlab.get("labEmulation")
    if isinstance(lab_emulation, dict):
        lab_scope = lab_emulation.get("scope")
        for item in _as_request_list(lab_emulation.get("requests")):
            enriched = dict(item)
            if lab_scope is not None and "scope" not in enriched:
                enriched["scope"] = lab_scope
            requests.append(enriched)
        for item in _as_request_list(lab_emulation.get("providerEmulation")):
            enriched = dict(item)
            if lab_scope is not None and "scope" not in enriched:
                enriched["scope"] = lab_scope
            requests.append(enriched)

    requests.extend(_as_request_list(containerlab.get("providerEmulation")))
    return requests


def render_lab_emulation_artifacts(site: SiteModel) -> List[Dict[str, Any]]:
    containerlab = _containerlab_inventory(site)
    requests = _lab_emulation_requests(containerlab)
    if not requests:
        return []

    has_capability = _has_lab_emulation_capability(containerlab)
    artifacts: List[Dict[str, Any]] = []
    for request in requests:
        mode = provider_emulation_mode(request)
        if not has_capability:
            raise ValueError(
                f"structured refusal: {mode} handoff input requires explicit lab-emulation capability"
            )
        artifacts.append(provider_emulation_artifact(request, mode))
    return artifacts
