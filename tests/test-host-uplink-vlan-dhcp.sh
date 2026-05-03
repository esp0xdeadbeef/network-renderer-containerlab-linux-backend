#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-test-three-site" "${tmp_dir}"

python3 - "${tmp_dir}/fabric.clab.yml" "${tmp_dir}/vm-bridges-generated.nix" <<'PY'
import json
import re
import sys
from pathlib import Path

topology = Path(sys.argv[1]).read_text()
bridges = Path(sys.argv[2]).read_text()

match = re.search(r"bridgeNetworks = builtins\.fromJSON ''\n(.*)\n  '';", bridges, re.S)
if not match:
    raise SystemExit("missing bridgeNetworks JSON")

bridge_networks = json.loads(match.group(1))

assert bridge_networks["br-uplink0"]["mode"] == "vlan"
assert bridge_networks["br-uplink0"]["parent"] == "eth0"
assert bridge_networks["br-uplink0"]["vlan"] == 4
assert bridge_networks["br-uplink1"]["mode"] == "vlan"
assert bridge_networks["br-uplink1"]["parent"] == "eth0"
assert bridge_networks["br-uplink1"]["vlan"] == 5

required = [
    "type: macvlan",
    "host-interface: eth0.4",
    "host-interface: eth0.5",
    "clab.host.vlan: '4'",
    "clab.host.vlan: '5'",
    "clab.host.parent: eth0",
    "clab.link.bridge: br-uplink0",
    "clab.link.bridge: br-uplink1",
]

missing = [needle for needle in required if needle not in topology]
if missing:
    raise SystemExit(f"missing rendered host-uplink markers: {missing}")

if "host:veth-br-upl" in topology:
    raise SystemExit("host uplinks must not be rendered as host veth bridge links")
PY

echo "PASS host-uplink-vlan-dhcp"
