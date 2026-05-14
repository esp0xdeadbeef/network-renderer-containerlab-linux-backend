#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  echo "WARN: direct repo tests are partial; set NETWORK_REPO_DIRECT_TEST_OK=1 for intentional focused runs, or run network-codex-agent/scripts/s-router-full-lab-rebuild-loop.sh for the locked full network-* sweep plus live validation." >&2
fi

"${repo_root}/tests/test-nix-file-loc.sh"
"${repo_root}/tests/test-python-file-loc.sh"
"${repo_root}/tests/test-s88-python-file-loc.sh"
"${repo_root}/tests/test-python-format.sh"
"${repo_root}/tests/test-s88-naming-and-hierarchy.sh"
"${repo_root}/tests/test-s88-python-readability.sh"
"${repo_root}/tests/test-rendered-artifact-validator-scratch-dir.sh"
"${repo_root}/tests/test-provenance-without-git.sh"
"${repo_root}/tests/test-policy-interface-tags-no-generated-link-parsing.sh"
"${repo_root}/tests/test-access-tenant-no-node-name-parsing.sh"
"${repo_root}/tests/test-vm-runtime-log-guard.sh"
"${repo_root}/tests/test-input-path-override.sh"
"${repo_root}/tests/test-vm-matrix-resources.sh"
"${repo_root}/tests/test-vm-matrix-runner.sh"
"${repo_root}/tests/test-passing-fixtures.sh"
"${repo_root}/tests/test-dual-wan-branch-overlay.sh"
"${repo_root}/tests/test-bgp-example.sh"
"${repo_root}/tests/test-routing-mode-required.sh"
"${repo_root}/tests/test-policy-firewall.sh"
"${repo_root}/tests/test-core-nat-wan.sh"
"${repo_root}/tests/test-management-eth0-egress-guard.sh"
"${repo_root}/tests/test-hostile-dns-east-west.sh"
"${repo_root}/tests/test-dns-service-policy-routes.sh"
"${repo_root}/tests/test-dns-service-source-binding.sh"
"${repo_root}/tests/test-hostile-gua-advertisements.sh"
"${repo_root}/tests/test-host-uplink-vlan-dhcp.sh"
"${repo_root}/tests/test-nat-uplink-runtime-addressing.sh"
"${repo_root}/tests/test-vm-nat-uplink.sh"
"${repo_root}/tests/test-vm-physical-overlay-post-checks.sh"
"${repo_root}/tests/test-s-router-clab-overlay-parity.sh"
"${repo_root}/tests/test-single-overlay-interface-link.sh"
"${repo_root}/tests/test-vm-example-lab-cleanup.sh"
"${repo_root}/tests/test-vm-docker-readiness.sh"
