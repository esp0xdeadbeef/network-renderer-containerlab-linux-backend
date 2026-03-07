# ./clabgen/s88/enterprise/inject_clients.py
from __future__ import annotations

import ipaddress

from clabgen.models import SiteModel, NodeModel, InterfaceModel


def _first_usable(network: ipaddress._BaseNetwork):
    if network.prefixlen >= (31 if isinstance(network, ipaddress.IPv4Network) else 127):
        return network.network_address
    return network.network_address + 1


def _second_usable(network: ipaddress._BaseNetwork):
    if network.prefixlen >= (31 if isinstance(network, ipaddress.IPv4Network) else 127):
        return network.broadcast_address
    return network.network_address + 2


def _derive_client(router_cidr: str) -> tuple[str, str]:
    iface = ipaddress.ip_interface(router_cidr)
    net = iface.network
    router_ip = iface.ip

    first = _first_usable(net)
    second = _second_usable(net)

    client = second if router_ip == first else first

    return str(router_ip), f"{client}/{net.prefixlen}"


def inject_clients(site: SiteModel) -> None:
    """
    Explicitly inject tenant client nodes for every access router tenant interface.
    """

    for node_name, node in list(site.nodes.items()):
        if node.role != "access":
            continue

        for ifname, iface in node.interfaces.items():
            if iface.kind != "tenant":
                continue

            if not iface.addr4:
                continue

            client_name = f"client-{node_name}-{ifname}"

            if client_name in site.nodes:
                continue

            router_v4, client_v4 = _derive_client(iface.addr4)

            routes = {
                "ipv4": [{"dst": "0.0.0.0/0", "via4": router_v4}],
                "ipv6": [],
            }

            if iface.addr6:
                router_v6, client_v6 = _derive_client(iface.addr6)
                routes["ipv6"].append({"dst": "::/0", "via6": router_v6})
            else:
                client_v6 = None

            site.nodes[client_name] = NodeModel(
                name=client_name,
                role="client",
                routing_domain=node.routing_domain,
                interfaces={
                    ifname: InterfaceModel(
                        name=ifname,
                        kind="tenant",
                        addr4=client_v4,
                        addr6=client_v6,
                        upstream=ifname,
                        routes=routes,
                    )
                },
            )

            site.links[ifname].endpoints[client_name] = {
                "node": client_name,
                "interface": ifname,
                "addr4": client_v4,
                "addr6": client_v6,
            }

            print(f"WARNING {client_name} injected to the config.")
