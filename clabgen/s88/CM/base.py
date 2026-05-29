from __future__ import annotations

from typing import Callable, Dict, List, Any

from .empty import render as render_empty
from .forwarding import render as render_forwarding
from .nat import render as render_nat
from .firewall import render as render_firewall
from .firewall_wan import render as render_wan_firewall
from .management_egress_guard import render as render_management_egress_guard


CM_BY_INPUT: Dict[str, Callable[[Dict[str, Any]], List[str]]] = {
    "empty": render_empty,
    "forwarding": render_forwarding,
    "firewall": render_firewall,
    "management_egress": render_management_egress_guard,
    "nat": render_nat,
    "wan_firewall": render_wan_firewall,
}

INPUT_ORDER: List[str] = [
    "empty",
    "forwarding",
    "wan_firewall",
    "nat",
    "firewall",
    "management_egress",
]


def _ordered_input_names(cm_inputs: Dict[str, Any]) -> List[str]:
    ordered: List[str] = []
    for input_name in INPUT_ORDER:
        if input_name in cm_inputs:
            ordered.append(input_name)

    for input_name in sorted(cm_inputs.keys()):
        if input_name not in ordered:
            ordered.append(input_name)

    return ordered


def _module_input(input_name: str, cm_inputs: Dict[str, Any]) -> Dict[str, Any]:
    module_input = cm_inputs.get(input_name, {})
    if module_input in (None, False):
        return {}
    if not isinstance(module_input, dict):
        raise ValueError(f"CM input {input_name!r} must be an object")
    return module_input


def render(cm_inputs: Dict[str, Any]) -> List[str]:
    cm_inputs = dict(cm_inputs or {})
    supported_inputs = ", ".join(sorted(CM_BY_INPUT.keys()))

    cmds: List[str] = []
    for input_name in _ordered_input_names(cm_inputs):
        fn = CM_BY_INPUT.get(input_name)
        if fn is None:
            module_input = cm_inputs.get(input_name)
            if module_input not in ({}, [], None, False):
                raise ValueError(
                    f"Unsupported CM input {input_name!r}; supported inputs: "
                    f"{supported_inputs}"
                )
            continue

        module_input = _module_input(input_name, cm_inputs)
        cmds.extend(fn(module_input))

    return cmds
