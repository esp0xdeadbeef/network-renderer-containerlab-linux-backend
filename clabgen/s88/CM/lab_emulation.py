from __future__ import annotations

import copy
import ipaddress
from typing import Any, Dict, List

from clabgen.models import SiteModel
from clabgen.s88.CM.dns_authority import normalize_dns_authority
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


def _controlled_dns_authority_artifact(site: SiteModel) -> Dict[str, Any] | None:
    authorities: List[tuple[str, Any, Dict[str, Any]]] = []
    for node_name, node in sorted(site.nodes.items()):
        services = node.services if isinstance(node.services, dict) else {}
        dns = services.get("dns")
        if not isinstance(dns, dict) or "validationAuthority" not in dns:
            continue
        authority = normalize_dns_authority(dns)["validationAuthority"]
        if authority is not None:
            authorities.append((node_name, node, authority))

    if not authorities:
        return None
    if len(authorities) != 1:
        raise ValueError(
            "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: the rendered site must "
            "own exactly one controlled authority; address material is "
            "intentionally omitted"
        )

    _node_name, node, authority = authorities[0]
    runtime_origin = (
        node.runtime_origin_egress
        if isinstance(node.runtime_origin_egress, dict)
        else {}
    )
    policy = runtime_origin.get("policyRouting")
    selected = authority["selectedUplink"]
    if not (
        runtime_origin.get("enabled") is True
        and runtime_origin.get("source") == "dns-service"
        and isinstance(policy, dict)
        and policy.get("source") == "control-plane-model"
        and policy.get("selectedUplink") == selected
        and runtime_origin.get("uplinks") == [selected]
    ):
        raise ValueError(
            "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: the controlled authority "
            "does not match the model-owned DNS egress selection; address "
            "material is intentionally omitted"
        )

    provider4 = copy.deepcopy(authority["provider"]["ipv4"])
    provider4["sourcePrefix"] = str(
        ipaddress.ip_interface(provider4["address"]).network
    )
    return {
        "name": f"{authority['traceId']}-controlled-dns-authority",
        "providerEmulationMode": "fake-provider",
        "scope": "harness",
        "harnessScoped": True,
        "ordinaryTargetOutput": False,
        "providerBridge": authority["provider"]["bridge"],
        "selectedUplink": selected,
        "alternateUplinks": copy.deepcopy(authority["alternateUplinks"]),
        "dhcp4": provider4,
        "ipv6": copy.deepcopy(authority["provider"]["ipv6"]),
        "dnsValidationAuthority": copy.deepcopy(authority),
    }


def render_lab_emulation_artifacts(site: SiteModel) -> List[Dict[str, Any]]:
    containerlab = _containerlab_inventory(site)
    requests = _lab_emulation_requests(containerlab)

    has_capability = _has_lab_emulation_capability(containerlab)
    artifacts: List[Dict[str, Any]] = []
    for request in requests:
        mode = provider_emulation_mode(request)
        if not has_capability:
            raise ValueError(
                f"diagnostic.ambiguous-target-capability: {mode} handoff input "
                f"requires explicit lab-emulation capability "
                f"(FS-310-HDS-010-SDS-010-SMS-020)"
            )
        artifact = provider_emulation_artifact(request, mode)
        _validate_limitation_record(artifact, mode)
        artifacts.append(artifact)

    controlled_authority = _controlled_dns_authority_artifact(site)
    if controlled_authority is not None:
        if artifacts:
            raise ValueError(
                "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: the controlled "
                "authority cannot share a site with another lab-emulation "
                "provider; address material is intentionally omitted"
            )
        artifacts.append(controlled_authority)

    return artifacts


UNAUTHORIZED_POLICY_FIELDS = frozenset({"defaultRoute", "defaultFirewall"})


def _validate_limitation_record(
    artifact: Dict[str, Any],
    mode: str,
) -> None:
    """Reject limitation records that create policy authority.

    FS-310-HDS-010-SDS-010-SMS-020 SN2: a limitation record must not
    include defaultRoute, defaultFirewall, or any field not authorized
    by an explicit CPM contract.
    """
    unauthorized = UNAUTHORIZED_POLICY_FIELDS & artifact.keys()
    if unauthorized:
        fields = ", ".join(sorted(unauthorized))
        raise ValueError(
            f"diagnostic.limitation-record-policy-authority: "
            f"{mode} lab-emulation limitation record includes "
            f"unauthorized policy field(s): {fields} "
            f"(FS-310-HDS-010-SDS-010-SMS-020)"
        )
