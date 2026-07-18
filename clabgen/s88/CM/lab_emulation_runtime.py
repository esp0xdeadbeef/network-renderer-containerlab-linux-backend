from __future__ import annotations

from typing import Any, Dict, List
import ipaddress
import re
import shlex

from clabgen.s88.site.naming import host_ifname
from clabgen.s88.site.naming import realized_bridge_name


def _slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return slug or "unnamed"


def _sh(command: str) -> str:
    return "sh -c " + shlex.quote(command)


def _live_vlan(artifact: Dict[str, Any]) -> int | None:
    live = artifact.get("liveUpstreamReachability")
    if isinstance(live, dict):
        vlan = live.get("vlan")
        if isinstance(vlan, int) and not isinstance(vlan, bool):
            return vlan
    vlan = artifact.get("liveUpstreamVlan")
    if isinstance(vlan, int) and not isinstance(vlan, bool):
        return vlan
    return None


def _bridge_for_vlan(bridge_networks: Dict[str, Any], vlan: int) -> str | None:
    for key, value in sorted(bridge_networks.items()):
        if not isinstance(value, dict):
            continue
        if value.get("mode") != "vlan" or value.get("vlan") != vlan:
            continue
        bridge = value.get("bridge")
        if isinstance(bridge, str) and bridge:
            return bridge
        if isinstance(key, str) and key:
            return key
    return None


def _required_string(mapping: Dict[str, Any], key: str, label: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"fake-provider lab-emulation runtime requires {label}.{key}")
    return value


def _dhcp_config_commands(
    name: str, dhcp4: Dict[str, Any], iface_name: str
) -> List[str]:
    address = _required_string(dhcp4, "address", "dhcp4")
    router = _required_string(dhcp4, "router", "dhcp4")
    range_start = _required_string(dhcp4, "rangeStart", "dhcp4")
    range_end = _required_string(dhcp4, "rangeEnd", "dhcp4")
    source_prefix = _required_string(dhcp4, "sourcePrefix", "dhcp4")
    lease_time = _required_string(dhcp4, "leaseTime", "dhcp4")

    try:
        iface = ipaddress.ip_interface(address)
        prefix = ipaddress.ip_network(source_prefix, strict=False)
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime has invalid IPv4 DHCP data for {name}"
        ) from exc
    if iface.version != 4 or prefix.version != 4:
        raise ValueError(
            f"fake-provider lab-emulation runtime requires IPv4 DHCP data for {name}"
        )

    try:
        lease_seconds = (
            int(lease_time[:-1]) * 60 if lease_time.endswith("m") else int(lease_time)
        )
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime leaseTime must be minutes or seconds for {name}"
        ) from exc

    netmask = str(prefix.netmask)
    config_lines = [
        f"start {range_start}",
        f"end {range_end}",
        f"interface {iface_name}",
        f"option subnet {netmask}",
        f"option router {router}",
        f"option lease {lease_seconds}",
        "lease_file /run/udhcpd/fake-provider.leases",
        "pidfile /run/udhcpd/fake-provider.pid",
    ]
    write_config_script = (
        "printf '%s\\n' "
        + " ".join(shlex.quote(line) for line in config_lines)
        + " > /run/udhcpd/fake-provider.conf"
    )
    write_config = "sh -c " + shlex.quote(write_config_script)
    return [
        "sysctl -w net.ipv4.ip_forward=1",
        f"ip addr replace {address} dev {iface_name}",
        f"ip link set {iface_name} up",
        "mkdir -p /run/udhcpd",
        write_config,
        "pkill -x udhcpd || true",
        "udhcpd /run/udhcpd/fake-provider.conf",
    ]


def _nat_commands(
    name: str, artifact: Dict[str, Any], dhcp4: Dict[str, Any]
) -> List[str]:
    nat44 = artifact.get("nat44")
    if not isinstance(nat44, dict) or nat44.get("enabled") is not True:
        return []
    source_prefix = nat44.get("sourcePrefix") or dhcp4.get("sourcePrefix")
    if not isinstance(source_prefix, str) or not source_prefix:
        raise ValueError(
            f"fake-provider lab-emulation runtime NAT44 requires sourcePrefix for {name}"
        )
    try:
        prefix = ipaddress.ip_network(source_prefix, strict=False)
    except ValueError as exc:
        raise ValueError(
            f"fake-provider lab-emulation runtime has invalid NAT44 sourcePrefix for {name}"
        ) from exc
    if prefix.version != 4:
        raise ValueError(
            f"fake-provider lab-emulation runtime NAT44 requires IPv4 sourcePrefix for {name}"
        )
    return [
        _sh(
            "\n".join(
                [
                    "set -e",
                    "nft add table ip nat 2>/dev/null || true",
                    'nft "add chain ip nat postrouting { type nat hook postrouting priority 100; policy accept; }" 2>/dev/null || true',
                    "nft flush chain ip nat postrouting",
                    f'nft add rule ip nat postrouting oifname "eth0" ip saddr {source_prefix} masquerade',
                    "nft list chain ip nat postrouting >/dev/null",
                ]
            )
        )
    ]


def _controlled_authority_commands(
    name: str, authority: Dict[str, Any], iface_name: str
) -> List[str]:
    def fail(reason: str) -> None:
        raise ValueError(
            "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: "
            + reason
            + "; address material is intentionally omitted"
        )

    def mapping(value: Any) -> Dict[str, Any]:
        if not isinstance(value, dict):
            fail("the controlled authority runtime is incomplete")
        return value

    def required(value: Dict[str, Any], key: str) -> str:
        item = value.get(key)
        if not isinstance(item, str) or not item:
            fail("the controlled authority runtime is incomplete")
        return item

    def one_address(value: Dict[str, Any], key: str, family: int) -> str:
        items = value.get(key)
        if not isinstance(items, list) or len(items) != 1:
            fail("the controlled authority runtime is ambiguous")
        try:
            address = ipaddress.ip_address(items[0])
        except (TypeError, ValueError):
            fail("the controlled authority runtime has malformed addressing")
        if address.version != family:
            fail("the controlled authority runtime has a family mismatch")
        return str(address)

    provider = mapping(authority.get("provider"))
    provider4 = mapping(provider.get("ipv4"))
    provider6 = mapping(provider.get("ipv6"))
    root = mapping(authority.get("root"))
    delegation = mapping(authority.get("delegation"))
    terminal = mapping(authority.get("terminal"))
    try:
        provider_interface4 = ipaddress.ip_interface(required(provider4, "address"))
        provider_interface6 = ipaddress.ip_interface(required(provider6, "address"))
        range_start = ipaddress.ip_address(required(provider4, "rangeStart"))
        range_end = ipaddress.ip_address(required(provider4, "rangeEnd"))
        router4 = ipaddress.ip_address(required(provider4, "router"))
        root4 = one_address(root, "ipv4", 4)
        root6 = one_address(root, "ipv6", 6)
        delegation4 = one_address(delegation, "ipv4", 4)
        delegation6 = one_address(delegation, "ipv6", 6)
        terminal4 = one_address(terminal, "ipv4", 4)
        terminal6 = one_address(terminal, "ipv6", 6)
    except ValueError:
        fail("the controlled authority runtime has malformed addressing")
    if not (
        provider_interface4.version == 4
        and provider_interface6.version == 6
        and all(
            value in provider_interface4.network
            for value in (range_start, range_end, router4)
        )
        and all(
            ipaddress.ip_address(value) in provider_interface4.network
            for value in (root4, delegation4, terminal4)
        )
        and all(
            ipaddress.ip_address(value) in provider_interface6.network
            for value in (root6, delegation6, terminal6)
        )
    ):
        fail("the controlled authority runtime addressing is inconsistent")

    root_zone = required(root, "zone")
    root_ns = required(root, "nameServer")
    delegation_zone = required(delegation, "zone")
    delegation_ns = required(delegation, "nameServer")
    terminal_name = required(terminal, "name")
    if not (
        root_zone == "."
        and re.fullmatch(r"^[A-Za-z0-9_.-]+\.$", root_ns)
        and re.fullmatch(r"^[A-Za-z0-9_.-]+\.$", delegation_zone)
        and delegation_zone != "."
        and re.fullmatch(r"^[A-Za-z0-9_.-]+\.$", delegation_ns)
        and re.fullmatch(r"^[A-Za-z0-9_.-]+\.$", terminal_name)
    ):
        fail("the controlled authority runtime hierarchy is malformed")

    dnsmasq_lines = [
        f"interface={iface_name}",
        "bind-interfaces",
        "port=0",
        "dhcp-authoritative",
        "enable-ra",
        f"dhcp-range={range_start},{range_end},{required(provider4, 'leaseTime')}",
        f"dhcp-option=option:router,{router4}",
        f"dhcp-range=::,constructor:{iface_name},ra-only,slaac,64,{required(provider6, 'leaseTime')}",
        "dhcp-leasefile=/run/clabgen-dnsmasq.leases",
        "pid-file=/run/clabgen-dnsmasq.pid",
    ]
    root_zone_lines = [
        "$ORIGIN .",
        "$TTL 60",
        f"@ IN SOA {root_ns} hostmaster.{delegation_zone} 1 60 60 60 60",
        f"@ IN NS {root_ns}",
        f"{root_ns} IN A {root4}",
        f"{root_ns} IN AAAA {root6}",
        f"{delegation_zone} IN NS {delegation_ns}",
        f"{delegation_ns} IN A {delegation4}",
        f"{delegation_ns} IN AAAA {delegation6}",
    ]
    delegation_zone_lines = [
        f"$ORIGIN {delegation_zone}",
        "$TTL 60",
        f"@ IN SOA {delegation_ns} hostmaster.{delegation_zone} 1 60 60 60 60",
        f"@ IN NS {delegation_ns}",
        f"{delegation_ns} IN A {delegation4}",
        f"{delegation_ns} IN AAAA {delegation6}",
        f"{terminal_name} IN A {terminal4}",
        f"{terminal_name} IN AAAA {terminal6}",
    ]
    knot_lines = [
        "server:",
        f'  listen: [ "{root4}@53", "{root6}@53", "{delegation4}@53", "{delegation6}@53" ]',
        "",
        "zone:",
        '  - domain: "."',
        '    file: "/run/clabgen-root.zone"',
        "",
        f'  - domain: "{delegation_zone}"',
        '    file: "/run/clabgen-delegation.zone"',
    ]
    authority_addresses = [root4, root6, delegation4, delegation6]
    authority_address_ready = " && ".join(
        "ip -o address show dev "
        + shlex.quote(iface_name)
        + " | "
        + f"awk -v address={shlex.quote(value)} "
        + '\'($4 == address || index($4, address "/") == 1) && '
        + "$0 !~ / (tentative|dadfailed)( |$)/ { found=1 } "
        + "END { exit !found }'"
        for value in authority_addresses
    )
    authority_socket_ready = " && ".join(
        "ss -H -lnut 'sport = :53' | "
        + f"grep -F -- {shlex.quote(value)} >/dev/null"
        for value in authority_addresses
    )

    def here_document(path: str, marker: str, lines: List[str]) -> List[str]:
        return [f"cat >{path} <<'{marker}'", *lines, marker]

    script = [
        "set -eu",
        "sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1",
        f"ip addr replace {provider_interface4} dev {iface_name}",
        f"ip -6 addr replace {provider_interface6} dev {iface_name}",
        f"ip addr replace {root4}/32 dev {iface_name}",
        f"ip -6 addr replace {root6}/128 dev {iface_name}",
        f"ip addr replace {delegation4}/32 dev {iface_name}",
        f"ip -6 addr replace {delegation6}/128 dev {iface_name}",
        f"ip link set {iface_name} up",
        "authority_addresses_ready=0",
        "for attempt in $(seq 1 3000); do",
        f"  if {authority_address_ready}; then authority_addresses_ready=1; break; fi",
        "  sleep 0.1",
        "done",
        "[ \"$authority_addresses_ready\" -eq 1 ] || { printf '%s\\n' 'DNS authority addresses did not become usable; address material is intentionally omitted' >&2; exit 1; }",
        *here_document(
            "/run/clabgen-dnsmasq.conf",
            "CLABGEN_DNSMASQ",
            dnsmasq_lines,
        ),
        "dnsmasq --test --conf-file=/run/clabgen-dnsmasq.conf",
        "pkill -x dnsmasq >/dev/null 2>&1 || true",
        "dnsmasq --conf-file=/run/clabgen-dnsmasq.conf",
        *here_document("/run/clabgen-root.zone", "CLABGEN_ROOT_ZONE", root_zone_lines),
        *here_document(
            "/run/clabgen-delegation.zone",
            "CLABGEN_DELEGATION_ZONE",
            delegation_zone_lines,
        ),
        *here_document("/run/clabgen-knot.conf", "CLABGEN_KNOT", knot_lines),
        "knotc --config=/run/clabgen-knot.conf conf-check",
        f"knotc --config=/run/clabgen-knot.conf zone-check . {delegation_zone}",
        "pkill -x knotd >/dev/null 2>&1 || true",
        "install -d -o knot -g knot /run/knot",
        "rm -f /run/clabgen-knot.pid",
        "nohup knotd --config=/run/clabgen-knot.conf >/tmp/clabgen-knot.log 2>&1 &",
        "knot_pid=$!",
        "echo \"$knot_pid\" >/run/clabgen-knot.pid",
        "authority_listeners_ready=0",
        "for attempt in $(seq 1 600); do",
        '  if kill -0 "$knot_pid"; then :; else break; fi',
        f"  if {authority_socket_ready}; then authority_listeners_ready=1; break; fi",
        "  sleep 0.1",
        "done",
        "if [ \"$authority_listeners_ready\" -ne 1 ]; then if kill -0 \"$knot_pid\"; then kill \"$knot_pid\"; fi; printf '%s\\n' 'DNS authority listeners did not remain available; address material is intentionally omitted' >&2; exit 1; fi",
    ]
    return [_sh("\n".join(script))]


def render_lab_emulation_runtime(
    artifacts: List[Dict[str, Any]],
    bridge_networks: Dict[str, Any],
) -> Dict[str, Any]:
    nodes: Dict[str, Any] = {}
    links: List[Dict[str, Any]] = []
    bridges: List[str] = []

    for artifact in artifacts:
        if artifact.get("providerEmulationMode") != "fake-provider":
            continue
        if (
            artifact.get("scope") != "harness"
            or artifact.get("harnessScoped") is not True
        ):
            raise ValueError(
                "fake-provider lab-emulation runtime must be harness scoped"
            )
        controlled_authority = artifact.get("dnsValidationAuthority")
        if isinstance(controlled_authority, dict):
            provider = controlled_authority.get("provider")
            provider_bridge = artifact.get("providerBridge")
            if not (
                controlled_authority.get("kind") == "controlled-iterative-hierarchy"
                and isinstance(provider, dict)
                and isinstance(provider_bridge, str)
                and provider_bridge
                and provider.get("bridge") == provider_bridge
                and artifact.get("selectedUplink") == provider_bridge
            ):
                raise ValueError(
                    "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: the controlled "
                    "authority provider binding is inconsistent; address material "
                    "is intentionally omitted"
                )
            bridge = realized_bridge_name(provider_bridge)
            bridge_network = bridge_networks.get(bridge)
            if not (
                isinstance(bridge_network, dict)
                and bridge_network.get("mode") == "isolated"
            ):
                raise ValueError(
                    "CLAB DNS DNS_VALIDATION_AUTHORITY_EXTERNAL: the selected "
                    "authority provider is not an isolated rendered bridge; "
                    "address material is intentionally omitted"
                )
            name = _slug(str(artifact.get("name") or "controlled-dns-authority"))
            node_name = f"lab-emulation-{name}"
            if node_name in nodes:
                raise ValueError(f"duplicate lab-emulation node {node_name!r}")
            provider_ifname = host_ifname(f"{node_name}-provider")
            nodes[node_name] = {
                "kind": "linux",
                "image": "clab-frr-plus-tooling:latest",
                "exec": _controlled_authority_commands(
                    name, controlled_authority, provider_ifname
                ),
                "labels": {
                    "clab.lab-emulation": "fake-provider",
                    "clab.lab-emulation.scope": "harness",
                    "clab.dns.validation-authority": "controlled-iterative-hierarchy",
                },
            }
            links.append(
                {
                    "endpoints": [
                        f"{node_name}:{provider_ifname}",
                        f"{bridge}:{host_ifname(f'{bridge}-{node_name}-{provider_ifname}')}",
                    ],
                    "labels": {
                        "clab.link.type": "lab-emulation",
                        "clab.link.bridge": bridge,
                    },
                }
            )
            bridges.append(bridge)
            continue

        dhcp4 = artifact.get("dhcp4")
        if not isinstance(dhcp4, dict):
            continue
        vlan = _live_vlan(artifact)
        if vlan is None:
            raise ValueError(
                "fake-provider lab-emulation runtime requires live upstream VLAN"
            )
        bridge = _bridge_for_vlan(bridge_networks, vlan)
        if bridge is None:
            raise ValueError(
                f"fake-provider lab-emulation runtime VLAN {vlan} has no rendered bridge network"
            )

        name = _slug(str(artifact.get("name") or "fake-provider"))
        node_name = f"lab-emulation-{name}"
        if node_name in nodes:
            raise ValueError(f"duplicate lab-emulation node {node_name!r}")
        provider_ifname = host_ifname(f"{node_name}-provider")

        exec_cmds = _dhcp_config_commands(name, dhcp4, provider_ifname) + _nat_commands(
            name, artifact, dhcp4
        )
        nodes[node_name] = {
            "kind": "linux",
            "image": "clab-frr-plus-tooling:latest",
            "exec": exec_cmds,
            "labels": {
                "clab.lab-emulation": "fake-provider",
                "clab.lab-emulation.scope": "harness",
            },
        }
        links.append(
            {
                "endpoints": [
                    f"{node_name}:{provider_ifname}",
                    f"{bridge}:{host_ifname(f'{bridge}-{node_name}-{provider_ifname}')}",
                ],
                "labels": {
                    "clab.link.type": "lab-emulation",
                    "clab.link.bridge": bridge,
                },
            }
        )
        bridges.append(bridge)

    return {"nodes": nodes, "links": links, "bridges": bridges}
