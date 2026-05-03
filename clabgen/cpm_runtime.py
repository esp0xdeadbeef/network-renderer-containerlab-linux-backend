from __future__ import annotations

from typing import Any, Dict


def _dict_value(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string_value(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _interface_overlay(kind: Any, backing_ref: Dict[str, Any], iface: Dict[str, Any]):
    overlay = _string_value(iface.get("overlay"))
    if overlay is not None:
        return overlay
    if kind == "overlay":
        return _string_value(backing_ref.get("name"))
    return None


def _interface_output(
    if_key: str,
    iface: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    backing_ref = _dict_value(iface.get("backingRef"))
    kind = iface.get("sourceKind") or iface.get("kind")
    attach = _dict_value(iface.get("attach"))
    attach_bridge = _string_value(attach.get("bridge"))
    host_uplink = _dict_value(iface.get("hostUplink"))

    if attach_bridge is not None:
        link_name = str(backing_ref.get("name") or if_key)
        if link_name:
            link_bridges[link_name] = attach_bridge
            if host_uplink:
                link_host_uplinks[link_name] = dict(host_uplink)

    return {
        "addr4": iface.get("addr4"),
        "addr6": iface.get("addr6"),
        "ll6": iface.get("ll6"),
        "routes": iface.get("routes") or {},
        "kind": kind,
        "upstream": iface.get("upstream") or iface.get("uplink"),
        "tenant": iface.get("tenant"),
        "overlay": _interface_overlay(kind, backing_ref, iface),
        "attachBridge": attach_bridge,
        "hostUplink": host_uplink,
    }


def _interface_outputs(
    runtime_target: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    realized = _dict_value(runtime_target.get("effectiveRuntimeRealization"))
    interfaces = _dict_value(realized.get("interfaces"))
    iface_out: Dict[str, Any] = {}

    for if_key, iface in interfaces.items():
        if not isinstance(if_key, str) or not if_key:
            continue
        if not isinstance(iface, dict):
            continue
        iface_out[if_key] = _interface_output(
            if_key, iface, link_bridges, link_host_uplinks
        )

    return iface_out


def _routing_mode(rt_name: str, runtime_target: Dict[str, Any]) -> str:
    routing_mode = runtime_target.get("routingMode")
    if not isinstance(routing_mode, str) or not routing_mode:
        raise ValueError(
            f"control_plane_model runtime target {rt_name!r} must include routingMode"
        )
    routing_mode = routing_mode.strip().lower()
    if routing_mode not in {"static", "bgp"}:
        raise ValueError(
            f"control_plane_model runtime target {rt_name!r} has invalid routingMode {routing_mode!r}"
        )
    return routing_mode


def _runtime_node_name(runtime_target: Dict[str, Any]) -> str | None:
    logical = _dict_value(runtime_target.get("logicalNode"))
    return _string_value(logical.get("name"))


def _loopback(runtime_target: Dict[str, Any]) -> Dict[str, Any]:
    realized = _dict_value(runtime_target.get("effectiveRuntimeRealization"))
    loopback = _dict_value(realized.get("loopback"))
    return {
        "ipv4": loopback.get("addr4"),
        "ipv6": loopback.get("addr6"),
    }


def _wan_link(
    node_name: str,
    if_key: str,
    iface: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    return {
        "kind": "wan",
        "bridge": iface.get("attachBridge") or link_bridges.get(if_key),
        "hostUplink": iface.get("hostUplink") or link_host_uplinks.get(if_key, {}),
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


def add_runtime_target(
    rt_name: str,
    runtime_target: Dict[str, Any],
    nodes: Dict[str, Any],
    links: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
) -> None:
    node_name = _runtime_node_name(runtime_target)
    if node_name is None:
        return

    iface_out = _interface_outputs(runtime_target, link_bridges, link_host_uplinks)
    nodes[node_name] = {
        "role": runtime_target.get("role") or "",
        "routingDomain": runtime_target.get("routingDomain") or "",
        "routing_mode": _routing_mode(rt_name, runtime_target),
        "bgp": runtime_target.get("bgp") or {},
        "interfaces": iface_out,
        "containers": runtime_target.get("containers") or [],
        "isolated": runtime_target.get("isolated") or False,
        "loopback": _loopback(runtime_target),
    }

    for if_key, iface in iface_out.items():
        if iface.get("kind") != "wan":
            continue
        link_name = f"wan-{node_name}-{if_key}"
        links[link_name] = _wan_link(
            node_name, if_key, iface, link_bridges, link_host_uplinks
        )
