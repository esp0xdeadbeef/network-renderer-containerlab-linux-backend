from __future__ import annotations

from typing import Callable, Dict, List, Any

from .empty import render as render_empty
from .forwarding import render as render_forwarding
from .nat import render as render_nat
from .firewall import render as render_firewall
from .firewall_wan import render as render_wan_firewall
from .management_egress_guard import render as render_management_egress_guard


CM_BY_ROLE: Dict[str, List[tuple[str, Callable[[Dict[str, Any]], List[str]]]]] = {
    "access": [("empty", render_empty)],
    "client": [("empty", render_empty)],
    "core": [("forwarding", render_forwarding), ("wan_firewall", render_wan_firewall)],
    "policy": [("forwarding", render_forwarding), ("firewall", render_firewall)],
    "downstream-selector": [("forwarding", render_forwarding)],
    "upstream-selector": [("forwarding", render_forwarding)],
    "wan-peer": [("forwarding", render_forwarding), ("nat", render_nat)],
    "isp": [("forwarding", render_forwarding)],
}


def render(role: str, cm_inputs: Dict[str, Any]) -> List[str]:
    if role not in CM_BY_ROLE:
        raise ValueError(f"No CM mapping for role={role!r}")

    cm_inputs = dict(cm_inputs or {})

    cmds: List[str] = []
    for input_name, fn in CM_BY_ROLE[role]:
        module_input = cm_inputs.get(input_name, {})
        if not isinstance(module_input, dict):
            raise ValueError(
                f"CM input {input_name!r} for role={role!r} must be an object"
            )
        cmds.extend(fn(module_input))
    cmds.extend(render_management_egress_guard(cm_inputs.get("management_egress", {})))
    return cmds
