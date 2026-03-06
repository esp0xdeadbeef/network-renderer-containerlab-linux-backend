from __future__ import annotations

from typing import Callable, Dict, List

from .empty import render as render_empty
from .forwarding import render as render_forwarding
from .nat import render as render_nat
from .firewall import render as render_firewall


CM_BY_ROLE: Dict[str, List[Callable[[str, str], List[str]]]] = {
    "access": [render_empty],
    "core": [render_forwarding],
    "upstream-selector": [render_forwarding],
    "policy": [render_forwarding, render_firewall],
    "wan-peer": [render_forwarding, render_nat],
    "isp": [render_forwarding],
}


def render(role: str, node_name: str) -> List[str]:
    if role not in CM_BY_ROLE:
        raise ValueError(f"No CM mapping for role={role!r} node={node_name!r}")

    cmds: List[str] = []
    for fn in CM_BY_ROLE[role]:
        cmds.extend(fn(role, node_name))
    return cmds
