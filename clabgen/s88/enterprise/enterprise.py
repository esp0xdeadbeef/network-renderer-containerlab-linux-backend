from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from clabgen.models import SiteModel
from clabgen.s88.enterprise.merge import merge_sites
from clabgen.s88.enterprise.overlay_gateways import with_overlay_gateways
from clabgen.s88.enterprise.site_loader import load_sites


class Enterprise:
    def __init__(self, sites: Dict[str, SiteModel]) -> None:
        self.sites = sites

    @classmethod
    def from_solver_json(
        cls,
        solver_json: str | Path,
        renderer_inventory: Dict[str, Any] | None = None,
    ) -> "Enterprise":
        return cls(
            load_sites(
                solver_json,
                renderer_inventory=renderer_inventory,
            )
        )

    def render(self) -> Dict[str, Any]:
        return merge_sites(with_overlay_gateways(self.sites))
