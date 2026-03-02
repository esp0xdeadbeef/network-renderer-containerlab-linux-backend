from __future__ import annotations

from typing import List, Dict, Any


def render_links(links: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Render containerlab links WITH bridge labels.
    Always emit deterministic bridge labels and preserve structure:
      - endpoints:
          - nodeA:ethX
          - nodeB:ethY
        labels:
          clab.link.type: bridge
          clab.link.bridge: <bridge-name>
    """
    rendered: List[Dict[str, Any]] = []

    for link in links:
        endpoints = link.get("endpoints", [])
        bridge = link.get("bridge")

        entry: Dict[str, Any] = {
            "endpoints": endpoints,
        }

        if bridge:
            entry["labels"] = {
                "clab.link.type": "bridge",
                "clab.link.bridge": bridge,
            }

        rendered.append(entry)

    return rendered
