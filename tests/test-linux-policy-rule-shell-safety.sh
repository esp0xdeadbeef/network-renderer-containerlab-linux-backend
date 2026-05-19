#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

python3 - <<'PY'
from clabgen.s88.CM.linux_policy_routes import render

node = {
    "interfaces": {
        "tenant": {
            "lane": {"access": "client"},
        },
        "uplink": {
            "addr4": "10.0.0.0/31",
            "addr6": "fd00::/127",
            "routes": {
                "ipv4": [
                    {
                        "dst": "0.0.0.0/0",
                        "via4": "10.0.0.1",
                        "policyOnly": True,
                        "lane": {"access": "client"},
                    }
                ],
                "ipv6": [
                    {
                        "dst": "::/0",
                        "via6": "fd00::1",
                        "policyOnly": True,
                        "lane": {"access": "client"},
                    }
                ],
            },
        },
    }
}

cmds = render(node, {"tenant": 1, "uplink": 2})
joined = "\n".join(cmds)

assert "ip route replace table 1001 0.0.0.0/0 via 10.0.0.1 dev eth2 onlink" in joined
assert "ip -6 route replace table 1001 ::/0 via fd00::1 dev eth2 onlink" in joined
assert "sh -c 'ip rule add iif eth1 priority 10001 table 1001 2>/dev/null || true'" in joined
assert "sh -c 'ip -6 rule add iif eth1 priority 10001 table 1001 2>/dev/null || true'" in joined

for cmd in cmds:
    if cmd.startswith(("ip rule add", "ip -6 rule add")):
        raise AssertionError(f"raw policy rule command is not shell-safe: {cmd}")

print("PASS linux-policy-rule-shell-safety")
PY
