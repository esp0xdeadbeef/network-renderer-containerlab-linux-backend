from __future__ import annotations

from typing import Any, Dict, List

from clabgen.s88.CM.linux_runtime import render as render_linux_runtime


def render(
    role: str,
    node_name: str,
    node_data: Dict[str, Any],
    eth_map: Dict[str, str],
) -> List[str]:
    return render_linux_runtime(role, node_name, node_data, eth_map)
