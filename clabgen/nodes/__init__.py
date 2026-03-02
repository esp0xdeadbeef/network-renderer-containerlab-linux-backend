# ./clabgen/nodes/__init__.py
from .access import render as render_access
from .policy import render as render_policy
from .upstream_selector import render as render_upstream_selector
from .core import render as render_core
from .wan_peer import render as render_wan_peer

__all__ = [
    "render_access",
    "render_policy",
    "render_upstream_selector",
    "render_core",
    "render_wan_peer",
]
