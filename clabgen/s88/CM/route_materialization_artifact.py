from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else []


def _placement_host(runtime_target: Dict[str, Any]) -> str | None:
    placement = runtime_target.get("placement")
    if isinstance(placement, dict):
        host = placement.get("host")
        if isinstance(host, str) and host.strip():
            return host.strip()
    host = runtime_target.get("host")
    if isinstance(host, str) and host.strip():
        return host.strip()
    return None


def _load_routes(control_plane: Dict[str, Any]) -> List[Dict[str, Any]]:
    """The canonical route set the bundle publishes.

    `network.data.canonicalRoutes` is the producer's flat, deduplicated route
    set (target, interface, family, destination, gateway, table, metric, kind).
    Reading it keeps this artifact off the plain control-plane model: the bundle
    is the input, and the canonical collection is the semantic content
    (FS-310, RR_RAW_CPM_INPUT).
    """
    network = _dict(control_plane.get("network"))
    data = _dict(network.get("data"))
    routes = data.get("canonicalRoutes")
    if not isinstance(routes, list):
        raise ValueError(
            "FS-310: the bundle carries no canonicalRoutes; the renderer must not "
            "reconstruct routes from the control-plane model"
        )
    return [_dict(entry) for entry in routes]


def _target_in_scope(entry: Dict[str, Any], deployment_host: str) -> bool:
    if not deployment_host:
        return True
    placement = entry.get("deploymentHost")
    return placement in (None, deployment_host)


def _route_record(
    target_name: str,
    ifkey: str,
    ifname: str,
    family: str,
    dst: str,
    via_key: str,
    via: str,
) -> Dict[str, Any]:
    return {
        "runtimeTarget": target_name,
        "interfaceKey": ifkey,
        "ifname": ifname,
        "family": family,
        "dst": dst,
        via_key: via,
        "source": "control-plane-model",
    }


def materialized_routes(control_plane: Dict[str, Any], deployment_host: str) -> List[Dict[str, Any]]:
    routes: List[Dict[str, Any]] = []
    seen: set[tuple[str, str, str, str, str]] = set()
    for entry in _load_routes(control_plane):
        if not _target_in_scope(entry, deployment_host):
            continue
        if entry.get("sourceKind") != "p2p":
            continue
        if entry.get("policyOnly") is True:
            continue
        family = "ipv6" if entry.get("family") == 6 else "ipv4"
        via_key = "via6" if family == "ipv6" else "via4"
        dst = entry.get("dst")
        via = entry.get("gateway")
        if not isinstance(dst, str) or not isinstance(via, str) or not via.strip():
            continue
        target_name = entry.get("target")
        ifkey = entry.get("interface")
        if not isinstance(target_name, str) or not target_name:
            raise ValueError(
                "FS-310: canonicalRoutes entry has no target; the renderer must "
                "not invent a runtime target"
            )
        if not isinstance(ifkey, str) or not ifkey:
            raise ValueError(
                "FS-310: canonicalRoutes entry has no interface; the renderer "
                "must not invent a route carrier"
            )
        ifname_value = entry.get("runtimeIfName")
        ifname = ifname_value if isinstance(ifname_value, str) and ifname_value else ifkey
        route_key = (target_name, ifname, family, dst, via.strip())
        if route_key in seen:
            continue
        seen.add(route_key)
        routes.append(_route_record(target_name, ifkey, ifname, family, dst, via_key, via.strip()))
    return routes


def write_artifact(cpm_json: Path, deployment_host: str, output_json: Path) -> None:
    control_plane = json.loads(cpm_json.read_text())
    payload = {
        "artifactKind": "containerlab-route-materialization",
        "renderer": "network-renderer-containerlab-linux-backend",
        "deploymentHost": deployment_host,
        "routes": materialized_routes(control_plane, deployment_host),
    }
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: python3 -m clabgen.s88.CM.route_materialization_artifact "
            "<control-plane-model.json> <deployment-host> <output.json>",
            file=sys.stderr,
        )
        return 2
    write_artifact(Path(argv[1]), argv[2], Path(argv[3]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
