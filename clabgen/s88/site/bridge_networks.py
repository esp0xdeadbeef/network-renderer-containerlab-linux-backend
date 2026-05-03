from __future__ import annotations

from typing import Any, Dict

from clabgen.models import SiteModel


def _host_bridge_networks(host_data: Dict[str, Any]) -> Dict[str, Any]:
    bridge_networks: Dict[str, Any] = {}

    uplinks = host_data.get("uplinks", {})
    if isinstance(uplinks, dict):
        for uplink_data in uplinks.values():
            if not isinstance(uplink_data, dict):
                continue
            bridge_name = uplink_data.get("bridge")
            if isinstance(bridge_name, str) and bridge_name:
                bridge_networks[bridge_name] = dict(uplink_data)

    bridges = host_data.get("bridgeNetworks", {})
    if isinstance(bridges, dict):
        for bridge_name, bridge_data in bridges.items():
            if not isinstance(bridge_name, str) or not bridge_name:
                continue
            if isinstance(bridge_data, dict) and bridge_data:
                bridge_networks.setdefault(bridge_name, dict(bridge_data))

    return bridge_networks


def renderer_bridge_networks(site: SiteModel) -> Dict[str, Any]:
    deployment = site.renderer_inventory.get("deployment", {})
    if not isinstance(deployment, dict):
        return {}

    hosts = deployment.get("hosts", {})
    if not isinstance(hosts, dict):
        return {}

    bridge_networks: Dict[str, Any] = {}
    for host_data in hosts.values():
        if not isinstance(host_data, dict):
            continue
        bridge_networks.update(_host_bridge_networks(host_data))

    return bridge_networks
