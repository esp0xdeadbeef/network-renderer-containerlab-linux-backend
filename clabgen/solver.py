from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, Tuple


def _strip_hash_comment_lines(text: str) -> str:
    lines = text.splitlines()
    while lines and lines[0].lstrip().startswith("#"):
        lines.pop(0)
    return "\n".join(lines).strip()


def _dump_parse_failure(path: Path, raw: str, errors: list[str]) -> None:
    header = f"[clabgen.solver] failed to parse solver input: {path}"
    divider = "-" * len(header)

    print(divider, file=sys.stderr)
    print(header, file=sys.stderr)
    print(divider, file=sys.stderr)

    for error in errors:
        print(error, file=sys.stderr)

    print("[clabgen.solver] raw input follows:", file=sys.stderr)
    print(raw, file=sys.stderr)
    print(divider, file=sys.stderr)


def _parse_json_candidates(path: Path, raw: str) -> Dict[str, Any]:
    candidates = [
        ("raw", raw),
        ("without-leading-hash-comments", _strip_hash_comment_lines(raw)),
    ]

    errors: list[str] = []

    for name, candidate in candidates:
        if not candidate:
            continue
        try:
            data = json.loads(candidate)
        except Exception as exc:
            errors.append(f"[candidate:{name}] {type(exc).__name__}: {exc}")
            continue

        if not isinstance(data, dict):
            raise ValueError("solver JSON top-level must be an object")

        return data

    _dump_parse_failure(path, raw, errors)

    if errors:
        raise ValueError(
            "unable to parse solver input as JSON; raw input dumped to stderr"
        )

    raise ValueError("solver input is empty")


def load_solver(path: Path) -> Dict[str, Any]:
    raw = path.read_text()
    parsed = _parse_json_candidates(path, raw)

    # Accept CPM JSON directly (control-plane model), and adapt it into the older
    # "solver JSON" shape expected by the rest of clabgen.
    if isinstance(parsed, dict) and "control_plane_model" in parsed:
        return _control_plane_model_to_solver_json(parsed)

    return parsed


def _control_plane_model_to_solver_json(root: Dict[str, Any]) -> Dict[str, Any]:
    cpm = root.get("control_plane_model")
    if not isinstance(cpm, dict):
        raise ValueError("'control_plane_model' must be an object")

    data = cpm.get("data")
    if not isinstance(data, dict):
        raise ValueError("'control_plane_model.data' must be an object")

    enterprise_out: Dict[str, Any] = {}

    for enterprise, sites_obj in data.items():
        if not isinstance(enterprise, str) or not enterprise:
            continue
        if not isinstance(sites_obj, dict):
            raise ValueError(f"control_plane_model.data.{enterprise} must be an object")

        site_out: Dict[str, Any] = {}

        for site_name, site_obj in sites_obj.items():
            if not isinstance(site_name, str) or not site_name:
                continue
            if not isinstance(site_obj, dict):
                raise ValueError(
                    f"control_plane_model.data.{enterprise}.{site_name} must be an object"
                )

            site_out[site_name] = _cpm_site_to_solver_site(site_obj)

        enterprise_out[enterprise] = {"site": site_out}

    meta = {
        "control_plane_model": cpm.get("meta", {}),
        "control_plane_model_version": cpm.get("version"),
    }

    return {
        "enterprise": enterprise_out,
        "meta": meta,
    }


def _cpm_site_to_solver_site(site: Dict[str, Any]) -> Dict[str, Any]:
    runtime_targets = site.get("runtimeTargets")
    if not isinstance(runtime_targets, dict):
        raise ValueError("control_plane_model site must include runtimeTargets object")

    nodes: Dict[str, Any] = {}
    links: Dict[str, Any] = {}

    # Nodes + their realized interfaces.
    for rt_name, rt in runtime_targets.items():
        if not isinstance(rt, dict):
            continue

        logical = rt.get("logicalNode") or {}
        if not isinstance(logical, dict):
            logical = {}
        node_name = logical.get("name")
        if not isinstance(node_name, str) or not node_name:
            continue

        realized = rt.get("effectiveRuntimeRealization") or {}
        if not isinstance(realized, dict):
            realized = {}

        ifaces = realized.get("interfaces") or {}
        if not isinstance(ifaces, dict):
            ifaces = {}

        iface_out: Dict[str, Any] = {}
        for if_key, iface in ifaces.items():
            if not isinstance(if_key, str) or not if_key:
                continue
            if not isinstance(iface, dict):
                continue

            backing_ref = iface.get("backingRef") or {}
            if not isinstance(backing_ref, dict):
                backing_ref = {}
            kind = iface.get("sourceKind") or iface.get("kind")
            overlay = iface.get("overlay")
            if not isinstance(overlay, str) or not overlay:
                if kind == "overlay":
                    overlay = backing_ref.get("name")
            if not isinstance(overlay, str) or not overlay:
                overlay = None
            iface_out[if_key] = {
                "addr4": iface.get("addr4"),
                "addr6": iface.get("addr6"),
                "ll6": iface.get("ll6"),
                "routes": iface.get("routes") or {},
                "kind": kind,
                "upstream": iface.get("upstream") or iface.get("uplink"),
                "tenant": iface.get("tenant"),
                "overlay": overlay,
            }

        loopback = realized.get("loopback") or {}
        if not isinstance(loopback, dict):
            loopback = {}

        routing_mode = rt.get("routingMode")
        if not isinstance(routing_mode, str) or not routing_mode:
            raise ValueError(
                f"control_plane_model runtime target {rt_name!r} must include routingMode"
            )
        routing_mode = routing_mode.strip().lower()
        if routing_mode not in {"static", "bgp"}:
            raise ValueError(
                f"control_plane_model runtime target {rt_name!r} has invalid routingMode {routing_mode!r}"
            )

        nodes[node_name] = {
            "role": rt.get("role") or "",
            "routingDomain": rt.get("routingDomain") or "",
            "routing_mode": routing_mode,
            "bgp": rt.get("bgp") or {},
            "interfaces": iface_out,
            "containers": rt.get("containers") or [],
            "isolated": rt.get("isolated") or False,
            "loopback": {
                "ipv4": loopback.get("addr4"),
                "ipv6": loopback.get("addr6"),
            },
        }

        # WAN links are not part of transit.adjacencies; synthesize link objects so the
        # existing WAN-peer injection logic can attach something to those interfaces.
        for if_key, iface in iface_out.items():
            if iface.get("kind") != "wan":
                continue

            link_name = f"wan-{node_name}-{if_key}"

            links[link_name] = {
                "kind": "wan",
                "endpoints": {
                    node_name: {
                        "node": node_name,
                        "interface": if_key,
                        "upstream": iface.get("upstream"),
                        "uplink": iface.get("upstream"),
                        "peerAddr4": None,
                        "peerAddr6": None,
                    }
                },
            }

    # Transit p2p links (lane-aware).
    transit = site.get("transit") or {}
    if not isinstance(transit, dict):
        transit = {}
    adjacencies = transit.get("adjacencies") or []
    if not isinstance(adjacencies, list):
        adjacencies = []

    for adj in adjacencies:
        if not isinstance(adj, dict):
            continue

        link_name = adj.get("link") or adj.get("name")
        if not isinstance(link_name, str) or not link_name:
            continue

        endpoints_out: Dict[str, Any] = {}
        endpoints = adj.get("endpoints") or []
        if not isinstance(endpoints, list):
            endpoints = []

        for ep in endpoints:
            if not isinstance(ep, dict):
                continue
            unit = ep.get("unit")
            if not isinstance(unit, str) or not unit:
                continue

            endpoints_out[unit] = {
                "node": unit,
                "interface": link_name,
            }

        links[link_name] = {
            "kind": adj.get("kind") or "p2p",
            "endpoints": endpoints_out,
        }

    # Preserve the non-realization parts the unit renderers expect.
    out = dict(site)
    out["nodes"] = nodes
    out["links"] = links

    return out


def extract_enterprise_sites(data: Dict[str, Any]) -> Iterable[Tuple[str, str, Dict[str, Any]]]:
    enterprise_root = data.get("enterprise")
    if not isinstance(enterprise_root, dict):
        raise ValueError("'enterprise' must be an object")

    for enterprise_name, enterprise_obj in enterprise_root.items():
        if not isinstance(enterprise_obj, dict):
            raise ValueError(f"enterprise.{enterprise_name} must be an object")

        site_root = enterprise_obj.get("site")
        if not isinstance(site_root, dict):
            raise ValueError(f"enterprise.{enterprise_name}.site must be an object")

        for site_name, site_obj in site_root.items():
            if not isinstance(site_obj, dict):
                raise ValueError(
                    f"enterprise.{enterprise_name}.site.{site_name} must be an object"
                )
            yield enterprise_name, site_name, site_obj


def validate_site_invariants(site: Dict[str, Any], context: Dict[str, str] | None = None) -> None:
    ctx = context or {}

    if "nodes" not in site or "links" not in site:
        raise ValueError(
            f"Invalid site schema for {ctx}: missing 'nodes' or 'links'"
        )

    if not isinstance(site.get("nodes"), dict):
        raise ValueError(f"Invalid site schema for {ctx}: 'nodes' must be an object")

    if not isinstance(site.get("links"), dict):
        raise ValueError(f"Invalid site schema for {ctx}: 'links' must be an object")

    if "coreNodeNames" in site and not isinstance(site.get("coreNodeNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'coreNodeNames' must be an array"
        )

    if "uplinkCoreNames" in site and not isinstance(site.get("uplinkCoreNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'uplinkCoreNames' must be an array"
        )

    if "uplinkNames" in site and not isinstance(site.get("uplinkNames"), list):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'uplinkNames' must be an array"
        )

    if "tenantPrefixOwners" in site and not isinstance(site.get("tenantPrefixOwners"), dict):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'tenantPrefixOwners' must be an object"
        )

    if "policyNodeName" in site and not isinstance(site.get("policyNodeName"), str):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'policyNodeName' must be a string"
        )

    if "upstreamSelectorNodeName" in site and not isinstance(site.get("upstreamSelectorNodeName"), str):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'upstreamSelectorNodeName' must be a string"
        )


def validate_routing_assumptions(site: Dict[str, Any]) -> Dict[str, Any]:
    _ = site
    return {
        "singleAccess": ""
    }
