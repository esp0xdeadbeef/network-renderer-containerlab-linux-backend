from __future__ import annotations

from typing import Any, Dict
import json

from clabgen.models import SiteModel
from clabgen.s88.site.access_tenants import (
    domains_external_names,
    policy_external_names,
)
from clabgen.s88.site.interface_tags import (
    add_interface_tag,
    interface_tag_values,
    policy_peer_map,
    tag_from_peer_role,
)
from clabgen.s88.site.overlay_paths import resolve_external_via_overlay


def build_policy_interface_tags(
    site: SiteModel,
    policy_node_name: str,
    eth_map: Dict[str, int],
    required_tenants: set[str],
    required_externals: set[str],
) -> Dict[str, Any]:
    interface_tags: Dict[str, Any] = {}
    peer_map = policy_peer_map(site, policy_node_name, eth_map)
    for peer in peer_map:
        tag_from_peer_role(site, interface_tags, f"eth{peer['eth']}", peer)
    if not interface_tags:
        raise RuntimeError(
            "policy interface tags cannot be resolved from topology\n"
            + json.dumps(peer_map, indent=2)
        )

    available_tags = interface_tag_values(interface_tags)
    if (
        "wan" not in available_tags
        and required_externals == {"wan"}
        and len(available_tags) == 1
    ):
        for only_interface in interface_tags.keys():
            interface_tags[only_interface] = "wan"
            break
        available_tags = {"wan"}

    declared_externals = domains_external_names(site) | policy_external_names(site)
    for external in sorted(required_externals):
        if external in available_tags:
            continue
        if external not in declared_externals:
            raise RuntimeError(
                f"external {external!r} referenced by communicationContract is not declared in site.domains.externals"
            )
        resolved_iface = resolve_external_via_overlay(
            site,
            policy_node_name=policy_node_name,
            peer_map=peer_map,
            external=external,
        )
        if resolved_iface is None:
            raise RuntimeError(
                "external has no policy-local tag and no overlay realization:\n"
                + json.dumps(
                    {
                        "external": external,
                        "declared_externals": sorted(declared_externals),
                        "interface_tags": interface_tags,
                    },
                    indent=2,
                )
            )
        add_interface_tag(interface_tags, resolved_iface, external)
        available_tags = interface_tag_values(interface_tags)

    _validate_required_tenants(interface_tags, available_tags, required_tenants)
    _validate_required_externals(interface_tags, available_tags, required_externals)
    return interface_tags


def _validate_required_tenants(
    interface_tags: Dict[str, Any],
    available_tags: set[str],
    required_tenants: set[str],
) -> None:
    for tenant in required_tenants:
        if tenant in available_tags:
            continue
        raise RuntimeError(
            "tenant cannot be mapped to any policy interface tag:\n"
            + json.dumps(
                {
                    "tenant": tenant,
                    "interface_tags": interface_tags,
                    "required_tenants": sorted(required_tenants),
                },
                indent=2,
            )
        )


def _validate_required_externals(
    interface_tags: Dict[str, Any],
    available_tags: set[str],
    required_externals: set[str],
) -> None:
    for external in required_externals:
        if external in available_tags:
            continue
        raise RuntimeError(
            "external cannot be mapped to any policy interface tag:\n"
            + json.dumps(
                {
                    "external": external,
                    "interface_tags": interface_tags,
                    "required_externals": sorted(required_externals),
                },
                indent=2,
            )
        )
