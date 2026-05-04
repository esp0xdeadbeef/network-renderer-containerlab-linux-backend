#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/tests/test-nix-file-loc.sh"
"${repo_root}/tests/test-python-file-loc.sh"
"${repo_root}/tests/test-s88-python-file-loc.sh"
"${repo_root}/tests/test-python-format.sh"
"${repo_root}/tests/test-s88-naming-and-hierarchy.sh"
"${repo_root}/tests/test-s88-python-readability.sh"
"${repo_root}/tests/test-passing-fixtures.sh"
"${repo_root}/tests/test-dual-wan-branch-overlay.sh"
"${repo_root}/tests/test-bgp-example.sh"
"${repo_root}/tests/test-routing-mode-required.sh"
"${repo_root}/tests/test-policy-firewall.sh"
"${repo_root}/tests/test-core-nat-wan.sh"
"${repo_root}/tests/test-management-eth0-egress-guard.sh"
"${repo_root}/tests/test-hostile-dns-east-west.sh"
"${repo_root}/tests/test-dns-service-policy-routes.sh"
"${repo_root}/tests/test-hostile-gua-advertisements.sh"
"${repo_root}/tests/test-host-uplink-vlan-dhcp.sh"
"${repo_root}/tests/test-s-router-clab-overlay-parity.sh"
