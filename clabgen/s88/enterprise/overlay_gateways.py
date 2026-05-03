from __future__ import annotations

from typing import Dict, List
import copy

from clabgen.models import SiteModel


def _overlay_endpoints(
    sites: Dict[str, SiteModel],
) -> Dict[tuple[str, str], List[Dict[str, str]]]:
    result: Dict[tuple[str, str], List[Dict[str, str]]] = {}

    for site in sites.values():
        site_id = f"{site.enterprise}.{site.site}"
        for node_name, node in site.nodes.items():
            for ifname, iface in node.interfaces.items():
                if iface.kind != "overlay":
                    continue
                endpoint = {
                    "site": site_id,
                    "node": node_name,
                    "interface": ifname,
                }
                if isinstance(iface.addr4, str) and iface.addr4:
                    endpoint["addr4"] = iface.addr4.split("/", 1)[0]
                if isinstance(iface.addr6, str) and iface.addr6:
                    endpoint["addr6"] = iface.addr6.split("/", 1)[0]
                result.setdefault((iface.overlay or ifname, site_id), []).append(
                    endpoint
                )

    return result


def with_overlay_gateways(sites: Dict[str, SiteModel]) -> Dict[str, SiteModel]:
    sites = copy.deepcopy(sites)
    overlay_endpoints = _overlay_endpoints(sites)

    for site in sites.values():
        site_id = f"{site.enterprise}.{site.site}"
        overlays = site.raw_transport.get("overlays", {})
        overlays = overlays if isinstance(overlays, dict) else {}

        for node in site.nodes.values():
            for iface in node.interfaces.values():
                if iface.kind != "overlay":
                    continue
                overlay_name = iface.overlay or iface.name
                overlay_spec = overlays.get(overlay_name, {})
                overlay_spec = overlay_spec if isinstance(overlay_spec, dict) else {}

                for family, via_key, addr_key in (
                    ("ipv4", "via4", "addr4"),
                    ("ipv6", "via6", "addr6"),
                ):
                    for route in iface.routes.get(family, []):
                        if (
                            not isinstance(route, dict)
                            or route.get("proto") != "overlay"
                        ):
                            continue
                        if route.get(via_key):
                            continue
                        peer_site = route.get("peerSite") or overlay_spec.get(
                            "peerSite"
                        )
                        if (
                            not isinstance(peer_site, str)
                            or not peer_site
                            or peer_site == site_id
                        ):
                            continue
                        gateway = None
                        endpoint_key = (overlay_name, peer_site)
                        for candidate in overlay_endpoints.get(endpoint_key, []):
                            candidate_address = candidate.get(addr_key)
                            if isinstance(candidate_address, str) and candidate_address:
                                gateway = candidate_address
                                break
                        if gateway:
                            route[via_key] = gateway

    return sites
