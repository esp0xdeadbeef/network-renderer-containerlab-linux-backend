from __future__ import annotations

from typing import Dict
from pathlib import Path

from .models import SiteModel
from .s88.enterprise.site_loader import load_sites


def parse_solver(path: str | Path) -> Dict[str, SiteModel]:
    return load_sites(Path(path))
