from __future__ import annotations

from typing import Any, Dict

from clabgen.cpm_runtime_wan import wan_link


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


def _list_strings(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item]


def _link_metadata(
    backing_ref: Dict[str, Any], iface: Dict[str, Any]
) -> Dict[str, Any]:
    lane = _dict_value(backing_ref.get("lane") or iface.get("lane"))
    lane_meta = _dict_value(backing_ref.get("laneMeta") or iface.get("laneMeta"))
    uplinks = _list_strings(backing_ref.get("uplinks")) or _list_strings(
        iface.get("uplinks")
    )
    overlay = _string_value(backing_ref.get("overlay")) or _string_value(
        iface.get("overlay")
    )
    return {
        "lane": lane,
        "laneMeta": lane_meta,
        "uplinks": uplinks,
        "overlay": overlay,
    }


def _merge_link_metadata(
    current: Dict[str, Any] | None, incoming: Dict[str, Any]
) -> Dict[str, Any]:
    merged = dict(current or {})
    for key in ("lane", "laneMeta"):
        value = incoming.get(key)
        if isinstance(value, dict) and value:
            merged[key] = value
    uplinks = incoming.get("uplinks")
    if isinstance(uplinks, list) and uplinks:
        merged["uplinks"] = sorted(set(_list_strings(merged.get("uplinks")) + uplinks))
    overlay = incoming.get("overlay")
    if isinstance(overlay, str) and overlay:
        merged["overlay"] = overlay
    return merged


def _interface_output(
    if_key: str,
    iface: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
    link_metadata: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    backing_ref = _dict_value(iface.get("backingRef"))
    kind = iface.get("sourceKind") or iface.get("kind")
    attach = _dict_value(iface.get("attach"))
    attach_bridge = _string_value(attach.get("bridge"))
    host_uplink = _dict_value(iface.get("hostUplink"))

    link_name = str(backing_ref.get("name") or if_key)
    if link_name:
        if attach_bridge is not None:
            link_bridges[link_name] = attach_bridge
            if host_uplink:
                link_host_uplinks[link_name] = dict(host_uplink)
        link_metadata[link_name] = _merge_link_metadata(
            link_metadata.get(link_name), _link_metadata(backing_ref, iface)
        )

    return {
        "addr4": iface.get("addr4"),
        "addr6": iface.get("addr6"),
        "ll6": iface.get("ll6"),
        "runtimeIfName": iface.get("runtimeIfName") or iface.get("renderedIfName"),
        "routes": iface.get("routes") or {},
        "kind": kind,
        "upstream": iface.get("upstream") or iface.get("uplink"),
        "tenant": iface.get("tenant"),
        "overlay": _interface_overlay(kind, backing_ref, iface),
        "lane": _dict_value(backing_ref.get("lane") or iface.get("lane")),
        "attachBridge": attach_bridge,
        "hostUplink": host_uplink,
    }


def _interface_outputs(
    runtime_target: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
    link_metadata: Dict[str, Dict[str, Any]],
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
            if_key, iface, link_bridges, link_host_uplinks, link_metadata
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


def add_runtime_target(
    rt_name: str,
    runtime_target: Dict[str, Any],
    nodes: Dict[str, Any],
    links: Dict[str, Any],
    link_bridges: Dict[str, str],
    link_host_uplinks: Dict[str, Dict[str, Any]],
    link_metadata: Dict[str, Dict[str, Any]],
) -> None:
    node_name = _runtime_node_name(runtime_target)
    if node_name is None:
        return

    iface_out = _interface_outputs(
        runtime_target, link_bridges, link_host_uplinks, link_metadata
    )
    nodes[node_name] = {
        "role": runtime_target.get("role") or "",
        "routingDomain": runtime_target.get("routingDomain") or "",
        "routing_mode": _routing_mode(rt_name, runtime_target),
        "bgp": runtime_target.get("bgp") or {},
        "interfaces": iface_out,
        "containers": runtime_target.get("containers") or [],
        "isolated": runtime_target.get("isolated") or False,
        "loopback": _loopback(runtime_target),
        "forwardingIntent": runtime_target.get("forwardingIntent") or {},
        "natIntent": runtime_target.get("natIntent") or {},
    }

    for if_key, iface in iface_out.items():
        if iface.get("kind") != "wan":
            continue
        link_name = f"wan-{node_name}-{if_key}"
        links[link_name] = wan_link(
            node_name, if_key, iface, link_bridges, link_host_uplinks
        )
