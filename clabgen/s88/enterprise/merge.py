from __future__ import annotations

from typing import Any, Dict, List
import copy

from clabgen.models import SiteModel
from clabgen.s88.enterprise.naming import scoped_node_name
from clabgen.s88.site.naming import bridge_name, host_ifname
from clabgen.s88.site.topology import render_site_topology


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list_strings(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    strings: List[str] = []
    for item in value:
        if isinstance(item, str) and item:
            strings.append(item)
    return strings


def _host_nat_commands(site: SiteModel) -> List[str]:
    hn = _dict(site.host_nat)
    if hn.get("required") is not True:
        return []
    bridge = hn.get("egressBridge")
    if not isinstance(bridge, str) or not bridge:
        return []
    prefixes = _list_strings(hn.get("hostMasqueradePrefixes4"))
    if not prefixes:
        return []
    vlan = hn.get("vlanId")
    if isinstance(vlan, int) and vlan > 0:
        oif = f"{bridge}.{vlan}"
    else:
        oif = bridge
    saddr = ", ".join(sorted(prefixes))
    return [
        f"nft add table ip nat",
        f"nft 'add chain ip nat POSTROUTING {{ type nat hook postrouting priority 101 ; policy accept ; }}'",
        f"nft add rule ip nat POSTROUTING oifname \"{oif}\" ip saddr {{ {saddr} }} masquerade",
    ]


def _rewrite_endpoint(
    endpoint: str, node_name_map: Dict[str, str], site: SiteModel
) -> str:
    if not isinstance(endpoint, str) or ":" not in endpoint:
        return endpoint

    endpoint_node_name, ifname = endpoint.split(":", 1)
    if endpoint_node_name == "host":
        return f"host:{host_ifname(f'{site.enterprise}-{site.site}-{ifname}')}"
    if endpoint_node_name in {"bridge", "macvlan", "mgmt-net"}:
        return endpoint

    rendered_node_name = node_name_map.get(endpoint_node_name)
    if rendered_node_name is None:
        raise ValueError(
            f"link references unknown rendered node '{endpoint_node_name}'"
        )

    return f"{rendered_node_name}:{ifname}"


def _rewrite_link(
    link_def: Dict[str, Any], node_name_map: Dict[str, str], site: SiteModel
) -> Dict[str, Any]:
    link_copy = copy.deepcopy(link_def)

    if "endpoints" in link_copy:
        endpoints: List[str] = []
        for endpoint in list(link_copy.get("endpoints", [])):
            endpoints.append(_rewrite_endpoint(endpoint, node_name_map, site))
        link_copy["endpoints"] = endpoints

    endpoint = link_copy.get("endpoint")
    if isinstance(endpoint, dict):
        node_name = endpoint.get("node")
        if isinstance(node_name, str) and node_name in node_name_map:
            endpoint["node"] = node_name_map[node_name]

    return link_copy


def merge_sites(sites: Dict[str, SiteModel]) -> Dict[str, Any]:
    merged_nodes: Dict[str, Any] = {}
    merged_links: List[Dict[str, Any]] = []
    merged_bridges: List[str] = []
    merged_bridge_networks: Dict[str, Any] = {}
    overlay_links: Dict[str, List[str]] = {}
    defaults: Dict[str, Any] | None = None
    solver_meta: Dict[str, Any] | None = None
    merged_host_nat_cmds: List[str] = []
    merged_lab_emulation_artifacts: List[Dict[str, Any]] = []

    for site_key in sorted(sites.keys()):
        site = sites[site_key]
        topo = render_site_topology(site)

        defaults = defaults or topo["topology"]["defaults"]
        solver_meta = solver_meta or dict(topo.get("solver_meta", {}) or {})
        node_name_map: Dict[str, str] = {}

        for node_name in sorted(topo["topology"]["nodes"].keys()):
            node_def = topo["topology"]["nodes"][node_name]
            if isinstance(node_def, dict) and node_def.get("kind") == "bridge":
                rendered_node_name = node_name
            else:
                rendered_node_name = scoped_node_name(site, node_name)
            if rendered_node_name in merged_nodes:
                existing = merged_nodes[rendered_node_name]
                if (
                    isinstance(existing, dict)
                    and isinstance(node_def, dict)
                    and existing.get("kind") == "bridge"
                    and node_def.get("kind") == "bridge"
                ):
                    node_name_map[node_name] = rendered_node_name
                    continue
                raise ValueError(f"duplicate rendered node '{rendered_node_name}'")
            node_name_map[node_name] = rendered_node_name
            merged_nodes[rendered_node_name] = copy.deepcopy(node_def)

        for link_def in topo["topology"]["links"]:
            link_copy = _rewrite_link(link_def, node_name_map, site)
            labels = dict(link_copy.get("labels", {}) or {})
            if labels.get("clab.link.type") == "overlay":
                overlay_name = labels.get("clab.overlay")
                if isinstance(overlay_name, str) and overlay_name:
                    overlay_links.setdefault(overlay_name, []).extend(
                        link_copy.get("endpoints", [])
                    )
                    continue
            merged_links.append(link_copy)

        merged_bridges.extend(list(topo.get("bridges", [])))
        merged_bridge_networks.update(dict(topo.get("bridge_networks", {}) or {}))
        for artifact in list(topo.get("lab_emulation_artifacts", []) or []):
            if isinstance(artifact, dict):
                merged_lab_emulation_artifacts.append(copy.deepcopy(artifact))

    for _site_key in sorted(sites.keys()):
        merged_host_nat_cmds.extend(_host_nat_commands(sites[_site_key]))

    for overlay_name in sorted(overlay_links.keys()):
        endpoints = sorted(set(overlay_links[overlay_name]))
        if not endpoints:
            continue
        bridge = bridge_name(f"overlay-{overlay_name}")
        if bridge in merged_nodes:
            raise ValueError(
                f"overlay bridge node collides with rendered node '{bridge}'"
            )
        merged_nodes[bridge] = {"kind": "bridge"}
        merged_bridges.append(bridge)
        for index, endpoint in enumerate(endpoints):
            merged_links.append(
                {
                    "endpoints": [
                        endpoint,
                        f"{bridge}:{host_ifname(f'{bridge}-{overlay_name}-{endpoint}')}",
                    ],
                    "labels": {
                        "clab.link.type": "overlay",
                        "clab.overlay": overlay_name,
                        "clab.link.bridge": bridge,
                    },
                }
            )

    return {
        "name": "fabric",
        "topology": {
            "defaults": defaults or {},
            "nodes": merged_nodes,
            "links": merged_links,
        },
        "bridges": sorted(set(merged_bridges)),
        "bridge_networks": merged_bridge_networks,
        "bridge_control_modules": {"hostNat": {"cmds": merged_host_nat_cmds}},
        "lab_emulation_artifacts": merged_lab_emulation_artifacts,
        "solver_meta": solver_meta or {},
    }
