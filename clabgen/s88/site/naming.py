from __future__ import annotations

import hashlib
from typing import Any, Dict

from clabgen.models import LinkModel, SiteModel

MAX_BRIDGE_NAME = 15


def bridge_name(seed: str) -> str:
    digest = hashlib.blake2s(seed.encode(), digest_size=6).hexdigest()
    return f"br-{digest}"[:MAX_BRIDGE_NAME]


def realized_bridge_name(name: str) -> str:
    if len(name) <= MAX_BRIDGE_NAME:
        return name
    return bridge_name(name)


def host_ifname(seed: str) -> str:
    digest = hashlib.blake2s(seed.encode(), digest_size=5).hexdigest()
    return f"veth-{digest}"[:MAX_BRIDGE_NAME]


def link_bridge(site: SiteModel, link: LinkModel, link_name: str) -> str:
    if link.bridge:
        return realized_bridge_name(link.bridge)
    raise ValueError(
        f"MISSING_CPM_BRIDGE_FIELD: link {link_name!r} has no explicit bridge field "
        f"(enterprise={site.enterprise!r} site={site.site!r}); "
        f"bridge must be explicitly provided by CPM link contract "
        f"(FS-720-HDS-030-SDS-010-SMS-041)"
    )


def host_uplink_interface(host_uplink: Dict[str, Any]) -> str | None:
    mode = host_uplink.get("mode")
    parent = host_uplink.get("parent")

    if not isinstance(parent, str) or not parent:
        return None

    ipv4_method = (host_uplink.get("ipv4") or {}).get("method")
    if not isinstance(mode, str) or not mode:
        if ipv4_method == "dhcp" or ipv4_method == "static":
            return parent
        return None

    if mode == "native" or mode == "nat":
        return parent

    vlan = host_uplink.get("vlan")
    if mode == "vlan" and isinstance(vlan, int):
        return f"{parent}.{vlan}"

    return None
