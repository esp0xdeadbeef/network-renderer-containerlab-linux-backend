from __future__ import annotations

import ipaddress

from clabgen.models import SiteModel, NodeModel, InterfaceModel


def _first_usable(network: ipaddress._BaseNetwork) -> ipaddress._BaseAddress:
    if isinstance(network, ipaddress.IPv4Network):
        if network.prefixlen >= 31:
            return network.network_address
        return network.network_address + 1

    if network.prefixlen >= 127:
        return network.network_address
    return network.network_address + 1


def _second_usable(network: ipaddress._BaseNetwork) -> ipaddress._BaseAddress:
    if isinstance(network, ipaddress.IPv4Network):
        if network.prefixlen >= 31:
            return network.broadcast_address
        return network.network_address + 2

    if network.prefixlen >= 127:
        return network.broadcast_address
    return network.network_address + 2


def _normalize_router_iface(
    cidr: str,
) -> ipaddress.IPv4Interface | ipaddress.IPv6Interface:
    iface = ipaddress.ip_interface(cidr)
    network = iface.network

    if iface.ip == network.network_address:
        iface = ipaddress.ip_interface(f"{_first_usable(network)}/{network.prefixlen}")

    return iface


def _derive_client_iface(cidr: str) -> tuple[str, str]:
    router_iface = _normalize_router_iface(cidr)
    network = router_iface.network
    router_ip = router_iface.ip

    first = _first_usable(network)
    second = _second_usable(network)

    client_ip = second if router_ip == first else first

    if client_ip == router_ip:
        raise RuntimeError(f"no distinct usable client address for {cidr}")

    return str(router_ip), f"{client_ip}/{network.prefixlen}"


def inject_clients(site: SiteModel) -> None:
    for node_name, node in list(site.nodes.items()):
        if node.role != "access":
            continue

        for ifname, iface in list(node.interfaces.items()):
            if iface.kind != "tenant":
                continue

            if not iface.addr4 and not iface.addr6:
                continue

            client_name = f"client-{node_name}-{ifname}"
            if client_name in site.nodes:
                continue

            router_v4: str | None = None
            client_v4: str | None = None
            router_v6: str | None = None
            client_v6: str | None = None

            routes = {
                "ipv4": [],
                "ipv6": [],
            }

            if iface.addr4:
                router_v4, client_v4 = _derive_client_iface(iface.addr4)
                routes["ipv4"].append(
                    {
                        "dst": "0.0.0.0/0",
                        "via4": router_v4,
                    }
                )

            if iface.addr6:
                router_v6, client_v6 = _derive_client_iface(iface.addr6)
                routes["ipv6"].append(
                    {
                        "dst": "::/0",
                        "via6": router_v6,
                    }
                )

            site.nodes[client_name] = NodeModel(
                name=client_name,
                role="client",
                routing_domain=node.routing_domain,
                interfaces={
                    ifname: InterfaceModel(
                        name=ifname,
                        addr4=client_v4,
                        addr6=client_v6,
                        kind="tenant",
                        tenant=iface.tenant,
                        upstream=ifname,
                        routes=routes,
                    )
                },
            )

            print(f"WARNING {client_name} injected to the config.")
