from __future__ import annotations

import ipaddress
import json


def _collect_connected_networks(node_data):
    nets4 = set()
    nets6 = set()

    for iface in node_data.get("interfaces", {}).values():
        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if addr4:
            try:
                iface4 = ipaddress.ip_interface(addr4)
                nets4.add(str(iface4.network))
            except Exception:
                pass

        if addr6:
            try:
                iface6 = ipaddress.ip_interface(addr6)
                nets6.add(str(iface6.network))
            except Exception:
                pass

    return sorted(nets4), sorted(nets6)


def _render_bgp_networks(node_data):
    nets4, nets6 = _collect_connected_networks(node_data)

    lines = []

    lines.append(" address-family ipv4 unicast")
    for n in nets4:
        lines.append(f"  network {n}")
    lines.append(" exit-address-family")
    lines.append(" !")

    lines.append(" address-family ipv6 unicast")
    for n in nets6:
        lines.append(f"  network {n}")
    lines.append(" exit-address-family")

    return lines


def _patch_frr_conf_remove_redistribute(frr_conf: str, node_data) -> str:
    cleaned = []

    for line in frr_conf.splitlines():
        if "redistribute connected" in line:
            continue
        if "redistribute static" in line:
            continue
        cleaned.append(line)

    patched = "\n".join(cleaned)

    network_lines = _render_bgp_networks(node_data)

    out = []
    injected = False

    for line in patched.splitlines():
        out.append(line)

        if line.strip() == "no bgp network import-check" and not injected:
            out.extend(network_lines)
            injected = True

    return "\n".join(out)


def _emit_frr_bootstrap(payload):
    cmds = []

    cmds.append("mkdir -p /var/run/frr /etc/frr")
    cmds.append("touch /etc/frr/daemons /etc/frr/frr.conf /etc/frr/vtysh.conf")

    payload_json = json.dumps(payload).replace('"', '\\"')

    python_cmd = (
        "python3 -c \"import json, pathlib\n"
        f"payload = json.loads(\\\"{payload_json}\\\")\n"
        "pathlib.Path('/etc/frr').mkdir(parents=True, exist_ok=True)\n"
        "daemon_lines = [f\"{k}={v}\" for k, v in payload['daemons'].items()]\n"
        "pathlib.Path('/etc/frr/daemons').write_text('\\n'.join(daemon_lines) + '\\n')\n"
        "pathlib.Path('/etc/frr/frr.conf').write_text(payload['frr_conf'])\n"
        "pathlib.Path('/etc/frr/vtysh.conf').write_text(payload['vtysh_conf'])\n"
        "\""
    )

    cmds.append(python_cmd)

    cmds.append("chown -R frr:frr /etc/frr /var/run/frr >/dev/null 2>&1 || true")
    cmds.append("chmod 640 /etc/frr/daemons /etc/frr/frr.conf /etc/frr/vtysh.conf >/dev/null 2>&1 || true")

    cmds.append("pkill -x zebra >/dev/null 2>&1 || true")
    cmds.append("pkill -x bgpd >/dev/null 2>&1 || true")

    cmds.append(
        "/usr/lib/frr/frrinit.sh restart >/dev/null 2>&1 || "
        "/etc/init.d/frr restart >/dev/null 2>&1 || "
        "service frr restart >/dev/null 2>&1 || true"
    )

    cmds.append("sleep 1")
    cmds.append("vtysh -c 'show bgp ipv4 summary' >/dev/null 2>&1 || true")
    cmds.append("vtysh -c 'show bgp ipv6 summary' >/dev/null 2>&1 || true")

    return cmds


def generate_frr_payload(node_name, node_data):
    router_id = None

    for iface in node_data.get("interfaces", {}).values():
        addr4 = iface.get("addr4")
        if addr4:
            router_id = addr4.split("/")[0]
            break

    if router_id is None:
        router_id = "1.1.1.1"

    local_as = abs(hash(node_name)) % 4294967294 + 1

    neighbors4 = set()
    neighbors6 = set()

    for iface in node_data.get("interfaces", {}).values():
        routes = iface.get("routes", [])

        for r in routes:
            if isinstance(r, dict):
                nh = r.get("via")
            else:
                continue

            if nh is None:
                continue

            try:
                ip = ipaddress.ip_address(nh)
                if isinstance(ip, ipaddress.IPv4Address):
                    neighbors4.add(str(ip))
                else:
                    neighbors6.add(str(ip))
            except Exception:
                pass

    daemons = {
        "zebra": "yes",
        "bgpd": "yes",
        "ospfd": "no",
        "ospf6d": "no",
        "ripd": "no",
        "ripngd": "no",
        "isisd": "no",
        "pimd": "no",
        "pim6d": "no",
        "ldpd": "no",
        "nhrpd": "no",
        "eigrpd": "no",
        "babeld": "no",
        "sharpd": "no",
        "staticd": "yes",
        "bfdd": "no",
        "fabricd": "no",
        "vrrpd": "no",
        "pathd": "no",
    }

    conf = []
    conf.append("frr defaults traditional")
    conf.append(f"hostname {node_name}")
    conf.append("service integrated-vtysh-config")
    conf.append("log stdout")
    conf.append("!")
    conf.append("ip forwarding")
    conf.append("ipv6 forwarding")
    conf.append("!")
    conf.append(f"router bgp {local_as}")
    conf.append(f" bgp router-id {router_id}")
    conf.append(" no bgp ebgp-requires-policy")
    conf.append(" no bgp network import-check")

    for n in sorted(neighbors4):
        conf.append(f" neighbor {n} remote-as external")

    for n in sorted(neighbors6):
        conf.append(f" neighbor {n} remote-as external")

    conf.append("!")

    conf.extend(_render_bgp_networks(node_data))

    conf.append("!")
    conf.append("line vty")
    conf.append("!")

    frr_conf = "\n".join(conf)

    vtysh_conf = "service integrated-vtysh-config\n"

    return {
        "daemons": daemons,
        "frr_conf": frr_conf,
        "vtysh_conf": vtysh_conf,
    }


def render_node_s88(node_name, node_data, eth_map, routing_mode="static", disable_dynamic=True):
    exec_cmds = []

    exec_cmds.append("sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'")

    for ifname, idx in eth_map.items():
        exec_cmds.append(f"ip link set {ifname} up")

        iface = node_data.get("interfaces", {}).get(ifname)
        if not iface:
            continue

        addr4 = iface.get("addr4")
        addr6 = iface.get("addr6")

        if addr4:
            exec_cmds.append(f"ip addr replace {addr4} dev {ifname}")

        if addr6:
            exec_cmds.append(f"ip -6 addr replace {addr6} dev {ifname}")

        if routing_mode == "static":
            for route in iface.get("routes", []):
                if not isinstance(route, dict):
                    continue

                dst = route.get("dst")
                via = route.get("via")

                if dst and via:
                    try:
                        ip = ipaddress.ip_network(dst, strict=False)
                        if isinstance(ip, ipaddress.IPv4Network):
                            exec_cmds.append(f"ip route replace {dst} via {via} dev {ifname} onlink")
                        else:
                            exec_cmds.append(f"ip -6 route replace {dst} via {via} dev {ifname} onlink")
                    except Exception:
                        pass

    if routing_mode == "bgp":
        payload = generate_frr_payload(node_name, node_data)
        payload["frr_conf"] = _patch_frr_conf_remove_redistribute(payload["frr_conf"], node_data)
        exec_cmds.extend(_emit_frr_bootstrap(payload))

    return exec_cmds
