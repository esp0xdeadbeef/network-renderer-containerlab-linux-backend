from __future__ import annotations

from typing import Dict, Any

from clabgen.models import NodeModel, SiteModel
from clabgen.s88.Unit.common import render_linux_node


def render(
    site: SiteModel,
    node_name: str,
    node: NodeModel,
    eth_map: Dict[str, int],
    extra: Dict[str, Any],
) -> Dict[str, Any]:
    _ = site
    return render_linux_node(
        node_name=node_name,
        node=node,
        eth_map=eth_map,
        extra=extra,
    )
