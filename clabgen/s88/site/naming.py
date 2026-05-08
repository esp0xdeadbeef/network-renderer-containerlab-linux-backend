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
    return bridge_name(f"{site.enterprise}-{site.site}-{link_name}")


def host_uplink_interface(host_uplink: Dict[str, Any]) -> str | None:
    mode = host_uplink.get("mode")
    parent = host_uplink.get("parent")

    if not isinstance(mode, str) or not isinstance(parent, str) or not parent:
        return None

    if mode == "native":
        return parent

    vlan = host_uplink.get("vlan")
    if mode == "vlan" and isinstance(vlan, int):
        return f"{parent}.{vlan}"

    return None
