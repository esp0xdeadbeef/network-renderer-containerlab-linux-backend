#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "${repo_root}/vm-network.nix" "${repo_root}/vm-network-nat.nix" <<'PY'
import sys
from pathlib import Path

vm_network = Path(sys.argv[1]).read_text()
vm_network_nat = Path(sys.argv[2]).read_text()

vm_network_required = [
    'rawBridgeNetworks = generated.bridgeNetworks or { };',
    'name = normalized.bridge or name;',
    'nat = import ./vm-network-nat.nix',
    'nat.networkConfigFor cfg',
    'dhcpServerConfig = nat.dhcpServerConfigFor cfg;',
]
vm_network_nat_required = [
    'natUplinks = lib.filterAttrs',
    'addressFor = network: (ipv4For network).address or "198.18.0.1/24";',
    'Address = [ (addressFor cfg) ];',
    'DHCPServer = true;',
    'IPv4Forwarding = true;',
    'IPMasquerade = "ipv4";',
    'dhcpServerConfigFor',
]
missing = [needle for needle in vm_network_required if needle not in vm_network]
missing += [needle for needle in vm_network_nat_required if needle not in vm_network_nat]
if missing:
    raise SystemExit(f"missing VM NAT uplink support: {missing}")
PY

echo "PASS vm-nat-uplink"
