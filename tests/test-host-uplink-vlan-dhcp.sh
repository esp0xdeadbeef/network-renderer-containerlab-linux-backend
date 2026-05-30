#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-overlay-dns-lane-policy" "${tmp_dir}"

python3 - "${tmp_dir}/fabric.clab.yml" "${tmp_dir}/vm-bridges-generated.nix" "${repo_root}/vm-network.nix" <<'PY'
import json
import re
import sys
from pathlib import Path

topology = Path(sys.argv[1]).read_text()
bridges = Path(sys.argv[2]).read_text()
vm_network_nix = Path(sys.argv[3]).read_text()

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
    "- admin:",
    "- client:",
    "- client2:",
    "- dmz:",
    "- branch:",
    "- hostile:",
    "- streaming:",
    "clab.host.interface: eth0.4",
    "clab.host.interface: eth0.5",
    "clab.host.interface: eth0.350",
    "clab.host.interface: eth0.351",
    "clab.host.interface: eth0.352",
    "clab.host.interface: eth0.353",
    "clab.host.interface: eth0.354",
    "clab.host.interface: eth0.355",
    "clab.host.interface: eth0.356",
    "clab.host.interface: eth0.357",
    "clab.host.vlan: '4'",
    "clab.host.vlan: '5'",
    "clab.host.vlan: '350'",
    "clab.host.vlan: '357'",
    "clab.host.parent: eth0",
    "clab.link.bridge: mgmt",
    "clab.link.bridge: streaming",
    "clab.link.bridge: br-uplink0",
    "clab.link.bridge: br-uplink1",
    "net.ipv6.conf.isp-a.accept_ra=2",
    "net.ipv6.conf.isp-a.autoconf=1",
    "udhcpc -b -i isp-a",
    "net.ipv6.conf.isp-b.accept_ra=2",
    "net.ipv6.conf.isp-b.autoconf=1",
    "udhcpc -b -i isp-b",
    "net.ipv6.conf.wan.accept_ra=2",
    "net.ipv6.conf.wan.autoconf=1",
    "udhcpc -b -i wan",
]

missing = [needle for needle in required if needle not in topology]
if missing:
    raise SystemExit(f"missing rendered host-uplink markers: {missing}")

if "host:veth-br-upl" in topology:
    raise SystemExit("host uplinks must not be rendered as host veth bridge links")

for bridge in ["mgmt", "admin", "client", "client2", "dmz", "branch", "hostile", "streaming"]:
    if f"clab.link.bridge: {bridge}" not in topology:
        raise SystemExit(f"missing access bridge marker {bridge}")

if re.search(r"(?m)^\s*-\s*macvlan:", topology):
    raise SystemExit("host uplinks must use explicit Containerlab bridge-kind links")

if 'DHCP = lib.mkIf (parentIf == "eth0") "ipv4";' not in vm_network_nix:
    raise SystemExit("VM eth0 lab-parent config must preserve DHCP for SSH hostfwd")

if 'dhcpV4Config = lib.optionalAttrs (parentIf == "eth0") { UseDNS = false; };' not in vm_network_nix:
    raise SystemExit("VM eth0 DHCP must avoid taking resolver state from QEMU usernet")
PY

echo "PASS host-uplink-vlan-dhcp"
