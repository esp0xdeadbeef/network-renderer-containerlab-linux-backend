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
    header = f"[clabgen.s88.solver] failed to parse solver input: {path}"
    divider = "-" * len(header)

    print(divider, file=sys.stderr)
    print(header, file=sys.stderr)
    print(divider, file=sys.stderr)

    for error in errors:
        print(error, file=sys.stderr)

    print("[clabgen.s88.solver] raw input follows:", file=sys.stderr)
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
    return _parse_json_candidates(path, raw)


def extract_enterprise_sites(
    data: Dict[str, Any],
) -> Iterable[Tuple[str, str, Dict[str, Any]]]:
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


def validate_site_invariants(
    site: Dict[str, Any], context: Dict[str, str] | None = None
) -> None:
    ctx = context or {}

    if "nodes" not in site or "links" not in site:
        raise ValueError(f"Invalid site schema for {ctx}: missing 'nodes' or 'links'")

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

    if "tenantPrefixOwners" in site and not isinstance(
        site.get("tenantPrefixOwners"), dict
    ):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'tenantPrefixOwners' must be an object"
        )

    if "policyNodeName" in site and not isinstance(site.get("policyNodeName"), str):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'policyNodeName' must be a string"
        )

    if "upstreamSelectorNodeName" in site and not isinstance(
        site.get("upstreamSelectorNodeName"), str
    ):
        raise ValueError(
            f"Invalid site schema for {ctx}: 'upstreamSelectorNodeName' must be a string"
        )


def validate_routing_assumptions(site: Dict[str, Any]) -> Dict[str, Any]:
    _ = site
    return {"singleAccess": ""}
