#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_wan_dynamic import render
from clabgen.s88.site.naming import host_uplink_interface

assert host_uplink_interface({"mode": "nat", "parent": "eth0"}) == "eth0"

node = {
    "interfaces": {
        "wan": {
            "kind": "wan",
            "hostUplink": {
                "mode": "nat",
                "ipv4": {"address": "198.18.0.1/24"},
            },
        }
    }
}

commands = render(node, {"wan": 2})
joined = "\n".join(commands)

assert "ip addr replace 198.18.0.2/24 dev eth2" in joined
assert "ip route replace default via 198.18.0.1 dev eth2 onlink" in joined
assert "udhcpc" not in joined
print("PASS nat-uplink-runtime-addressing")
PY
