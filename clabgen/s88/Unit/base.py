from __future__ import annotations

from typing import Any, Dict, List, Tuple

from clabgen.models import SiteModel
from clabgen.s88.site.topology import render_site_topology


def render_units(
    site: SiteModel,
) -> Tuple[Dict[str, Any], List[Dict[str, Any]], List[str]]:
    topology = render_site_topology(site)
    return (
        topology["topology"]["nodes"],
        topology["topology"]["links"],
        topology["bridges"],
    )
