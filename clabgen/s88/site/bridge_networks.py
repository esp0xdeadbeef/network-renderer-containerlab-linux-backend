from __future__ import annotations

from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.site.naming import realized_bridge_name


def _target_host(site: SiteModel) -> str | None:
    containerlab = site.renderer_inventory.get("containerlab")
    if not isinstance(containerlab, dict):
        return None
    for key in ("targetHost", "deploymentHost", "host"):
        value = containerlab.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _add_bridge_network(
    bridge_networks: Dict[str, Any], bridge_name: str, bridge_data: Dict[str, Any]
) -> None:
    rendered_bridge = realized_bridge_name(bridge_name)
    rendered_data = dict(bridge_data)
    rendered_data["bridge"] = rendered_bridge
    existing = bridge_networks.get(rendered_bridge)
    if existing is not None and existing != rendered_data:
        raise ValueError(
            f"multiple bridge network definitions render to {rendered_bridge!r}"
        )
    bridge_networks[rendered_bridge] = rendered_data


def _host_bridge_networks(host_data: Dict[str, Any]) -> Dict[str, Any]:
    bridge_networks: Dict[str, Any] = {}

    uplinks = host_data.get("uplinks", {})
    if isinstance(uplinks, dict):
        for uplink_data in uplinks.values():
            if not isinstance(uplink_data, dict):
                continue
            bridge_name = uplink_data.get("bridge")
            if isinstance(bridge_name, str) and bridge_name:
                _add_bridge_network(bridge_networks, bridge_name, uplink_data)

    bridges = host_data.get("bridgeNetworks", {})
    if isinstance(bridges, dict):
        for bridge_name, bridge_data in bridges.items():
            if not isinstance(bridge_name, str) or not bridge_name:
                continue
            if isinstance(bridge_data, dict) and bridge_data:
                rendered_bridge = realized_bridge_name(bridge_name)
                if rendered_bridge not in bridge_networks:
                    _add_bridge_network(bridge_networks, bridge_name, bridge_data)

    return bridge_networks


def renderer_bridge_networks(site: SiteModel) -> Dict[str, Any]:
    deployment = site.renderer_inventory.get("deployment", {})
    if not isinstance(deployment, dict):
        return {}

    hosts = deployment.get("hosts", {})
    if not isinstance(hosts, dict):
        return {}

    target_host = _target_host(site)
    if target_host is None:
        host_values = hosts.values()
    else:
        host_data = hosts.get(target_host)
        host_values = [host_data] if isinstance(host_data, dict) else []

    bridge_networks: Dict[str, Any] = {}
    for host_data in host_values:
        if not isinstance(host_data, dict):
            continue
        bridge_networks.update(_host_bridge_networks(host_data))

    return bridge_networks
