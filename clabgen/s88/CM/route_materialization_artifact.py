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


def _iter_runtime_targets(control_plane: Dict[str, Any]) -> Iterable[tuple[str, Dict[str, Any]]]:
    data = _dict(_dict(control_plane).get("control_plane_model")).get("data")
    for enterprise in _dict(data).values():
        for site in _dict(enterprise).values():
            for target_name, runtime_target in _dict(_dict(site).get("runtimeTargets")).items():
                yield str(target_name), _dict(runtime_target)


def _target_in_scope(runtime_target: Dict[str, Any], deployment_host: str) -> bool:
    if not deployment_host:
        return True
    return _placement_host(runtime_target) == deployment_host


def _route_dst(route: Dict[str, Any]) -> str | None:
    for key in ("dst", "destination", "prefix"):
        value = route.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


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
    for target_name, runtime_target in _iter_runtime_targets(control_plane):
        if not _target_in_scope(runtime_target, deployment_host):
            continue
        interfaces = _dict(_dict(runtime_target.get("effectiveRuntimeRealization")).get("interfaces"))
        for ifkey, iface_value in sorted(interfaces.items()):
            iface = _dict(iface_value)
            if iface.get("sourceKind") != "p2p":
                continue
            ifname = iface.get("runtimeIfName") or iface.get("renderedIfName") or ifkey
            if not isinstance(ifname, str) or not ifname.strip():
                ifname = str(ifkey)
            route_lists = _dict(iface.get("routes"))
            for route_value in _list(route_lists.get("ipv4")):
                route = _dict(route_value)
                if route.get("policyOnly") is True:
                    continue
                dst = _route_dst(route)
                via = route.get("via4")
                if isinstance(dst, str) and isinstance(via, str) and via.strip():
                    route_key = (target_name, ifname, "ipv4", dst, via.strip())
                    if route_key not in seen:
                        seen.add(route_key)
                        routes.append(_route_record(target_name, str(ifkey), ifname, "ipv4", dst, "via4", via.strip()))
            for route_value in _list(route_lists.get("ipv6")):
                route = _dict(route_value)
                if route.get("policyOnly") is True:
                    continue
                dst = _route_dst(route)
                via = route.get("via6")
                if isinstance(dst, str) and isinstance(via, str) and via.strip():
                    route_key = (target_name, ifname, "ipv6", dst, via.strip())
                    if route_key not in seen:
                        seen.add(route_key)
                        routes.append(_route_record(target_name, str(ifkey), ifname, "ipv6", dst, "via6", via.strip()))
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
