#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_routes import _render_default_routes, _render_static_routes

node = {
    "interfaces": {
        "left": {
            "addr4": "10.0.0.0/31",
            "addr6": "fd00::/127",
            "routes": {
                "ipv4": [
                    {"dst": "10.20.0.0/24", "via4": "10.0.0.1"},
                    {"dst": "0.0.0.0/0", "via4": "10.0.0.1"},
                ],
                "ipv6": [
                    {"dst": "fd20::/64", "via6": "fd00::1"},
                    {"dst": "::/0", "via6": "fd00::1"},
                ],
            },
        },
        "right": {
            "addr4": "10.0.0.2/31",
            "addr6": "fd00::2/127",
            "routes": {
                "ipv4": [
                    {"dst": "10.20.0.0/24", "via4": "10.0.0.3"},
                    {"dst": "0.0.0.0/0", "via4": "10.0.0.3"},
                ],
                "ipv6": [
                    {"dst": "fd20::/64", "via6": "fd00::3"},
                    {"dst": "::/0", "via6": "fd00::3"},
                ],
            },
        },
    }
}

eth_map = {"left": 1, "right": 2}
static_cmds = _render_static_routes(node, eth_map)
default_cmds = _render_default_routes(node, eth_map)
joined = "\n".join(static_cmds + default_cmds)

assert (
    "ip route replace 10.20.0.0/24 "
    "nexthop via 10.0.0.1 dev eth1 onlink "
    "nexthop via 10.0.0.3 dev eth2 onlink"
) in joined
assert (
    "ip -6 route replace fd20::/64 "
    "nexthop via fd00::1 dev eth1 onlink "
    "nexthop via fd00::3 dev eth2 onlink"
) in joined
assert (
    "ip route replace default "
    "nexthop via 10.0.0.1 dev eth1 onlink "
    "nexthop via 10.0.0.3 dev eth2 onlink"
) in joined
assert (
    "ip -6 route replace default "
    "nexthop via fd00::1 dev eth1 onlink "
    "nexthop via fd00::3 dev eth2 onlink"
) in joined
assert "ip route replace 10.20.0.0/24 via 10.0.0.1" not in joined
assert "ip route replace 10.20.0.0/24 via 10.0.0.3" not in joined
print("PASS linux-route-multipath")
PY
