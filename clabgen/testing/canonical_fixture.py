from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict


def _by_enterprise(payload: Dict[str, Any]) -> Dict[str, Any]:
    """canonicalSites.byEnterprise, from the fixture's `data` map."""
    data = payload.get("data")
    if not isinstance(data, dict):
        return {"byEnterprise": {}}
    return {"byEnterprise": data}


def _targets(payload: Dict[str, Any]) -> Dict[str, Any]:
    """canonicalRuntimeTargets.targets, flattened from the fixture's sites."""
    out = []
    data = payload.get("data") or {}
    for enterprise, sites in data.items():
        if not isinstance(sites, dict):
            continue
        for site_name, site in sites.items():
            if not isinstance(site, dict):
                continue
            for target, record in (site.get("runtimeTargets") or {}).items():
                if not isinstance(record, dict):
                    continue
                out.append(
                    {"target": target, "enterprise": enterprise, "site": site_name, **record}
                )
    return {"targets": out}


def _interfaces(payload: Dict[str, Any]) -> list:
    out = []
    data = payload.get("data") or {}
    for enterprise, sites in data.items():
        if not isinstance(sites, dict):
            continue
        for site_name, site in sites.items():
            if not isinstance(site, dict):
                continue
            for target, record in (site.get("runtimeTargets") or {}).items():
                if not isinstance(record, dict):
                    continue
                interfaces = (
                    (record.get("effectiveRuntimeRealization") or {}).get("interfaces") or {}
                )
                if not isinstance(interfaces, dict):
                    continue
                for if_name, iface in interfaces.items():
                    if isinstance(iface, dict):
                        out.append(
                            {
                                "canonicalPath": (
                                    f"/data/{enterprise}/{site_name}/runtimeTargets/"
                                    f"{target}/interfaces/{if_name}"
                                ),
                                "identity": {"name": if_name},
                                **iface,
                            }
                        )
    return out


def _routes(payload: Dict[str, Any]) -> list:
    out = []
    data = payload.get("data") or {}
    for enterprise, sites in data.items():
        if not isinstance(sites, dict):
            continue
        for site_name, site in sites.items():
            if not isinstance(site, dict):
                continue
            for target, record in (site.get("runtimeTargets") or {}).items():
                if not isinstance(record, dict):
                    continue
                interfaces = (
                    (record.get("effectiveRuntimeRealization") or {}).get("interfaces") or {}
                )
                if not isinstance(interfaces, dict):
                    continue
                for if_name, iface in interfaces.items():
                    if not isinstance(iface, dict):
                        continue
                    routes = iface.get("routes") or {}
                    if not isinstance(routes, dict):
                        continue
                    for family in ("ipv4", "ipv6"):
                        for route in routes.get(family) or []:
                            if isinstance(route, dict):
                                out.append(
                                    {
                                        "runtimeIfName": iface.get("runtimeIfName", if_name),
                                        "family": 4 if family == "ipv4" else 6,
                                        **route,
                                    }
                                )
    return out


def _forwarding(payload: Dict[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    data = payload.get("data") or {}
    for sites in data.values():
        if not isinstance(sites, dict):
            continue
        for site in sites.values():
            if not isinstance(site, dict):
                continue
            for relation in site.get("relations") or []:
                if isinstance(relation, dict) and isinstance(relation.get("id"), str):
                    out[relation["id"]] = relation
    return {"relations": out}


def _overlays(payload: Dict[str, Any]) -> Dict[str, Any]:
    overlays: Dict[str, Any] = {}
    data = payload.get("data") or {}
    for sites in data.values():
        if not isinstance(sites, dict):
            continue
        for site in sites.values():
            if not isinstance(site, dict):
                continue
            for name, record in (site.get("overlays") or {}).items():
                overlays[name] = record
    return {"overlays": overlays, "byOverlay": overlays}


_CANONICAL_PROJECTIONS = {
    "canonicalSites": _by_enterprise,
    "canonicalRuntimeTargets": _targets,
    "canonicalInterfaces": _interfaces,
    "canonicalRoutes": _routes,
    "canonicalForwarding": _forwarding,
    "canonicalOverlays": _overlays,
}


def canonical_bundle_path(
    repo_root: Path, cpm: Dict[str, Any], scope: str, dest: Path | None = None
) -> Path:
    """Release a CPM fixture into a canonical bundle and return its path.

    The bundle is produced by network-realization-model (release + validation);
    the test never fabricates the release stamp.
    """
    root = Path(repo_root)
    helper = root / "tests" / "lib" / "canonical-bundle.sh"
    if not helper.exists():
        raise RuntimeError(f"canonical bundle helper missing: {helper}")

    payload = cpm.get("control_plane_model", cpm)
    # FS-310-HDS-040-SDS-010-SMS-100: a fixture CPM is a hand-written miniature
    # of what the real producer emits. The real producer publishes the canonical
    # collections alongside `data`, and network-realization-model's `canonicalFor`
    # PROJECTS them -- it does not synthesise them. A fixture that only wrote
    # `data` therefore realised to `canonical = {}`, and the renderer had nothing
    # it was allowed to map (correctly: an empty projection is the model saying
    # "nothing published", not "please fall back").
    #
    # So the fixture states the collections it is claiming to publish, built from
    # its own `data` in the canonical shapes. This is test DATA describing a
    # producer, not renderer logic: it lives in clabgen/testing/, never in the
    # render path, and the renderer below it still maps only `canonical.*`.
    payload = dict(payload)
    for name, project in _CANONICAL_PROJECTIONS.items():
        payload.setdefault(name, project(payload))
    tmp = Path(tempfile.mkdtemp(prefix="clab-canonical-fixture-"))
    cpm_path = tmp / "cpm.json"
    cpm_path.write_text(json.dumps({"control_plane_model": payload}))
    bundle_path = Path(dest) if dest is not None else tmp / "bundle.json"

    subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; emit_canonical_bundle "$2" "$3" "$4"',
            "canonical-bundle",
            str(helper),
            str(cpm_path),
            str(bundle_path),
            scope,
        ],
        check=True,
        cwd=str(root),
        env={**os.environ, "SMS_TEST_REPO_ROOT": str(root)},
    )
    return bundle_path


__all__ = ["canonical_bundle_path"]
