from __future__ import annotations

from typing import Dict, Any

from clabgen.models import NodeModel, SiteModel
from clabgen.s88.Unit.common import render_linux_node
from clabgen.s88.Unit.firewall_context import build_node_firewall_context


def render(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any],
) -> Dict[str, Any]:
    merged_extra = dict(extra)
    merged_extra["firewall_context"] = build_node_firewall_context(
        site=site,
        node_name=node_name,
        node=node,
        eth_map=eth_map,
    )

    return render_linux_node(
        node_name=node_name,
        node=node,
        eth_map=eth_map,
        extra=merged_extra,
    )
