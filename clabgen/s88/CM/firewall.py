# ./clabgen/s88/CM/firewall.py
from __future__ import annotations

from typing import List


def render(role: str, node_name: str) -> List[str]:
    _ = node_name

    if role != "policy":
        return []

    return []
