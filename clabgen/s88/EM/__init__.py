from __future__ import annotations

from typing import Any

__all__ = ["render"]


def render(*args: Any, **kwargs: Any) -> list[str]:
    from .base import render as render_base

    return render_base(*args, **kwargs)
