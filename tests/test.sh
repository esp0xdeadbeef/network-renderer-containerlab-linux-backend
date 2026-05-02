#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/tests/test-passing-fixtures.sh"
"${repo_root}/tests/test-dual-wan-branch-overlay.sh"
"${repo_root}/tests/test-bgp-example.sh"
"${repo_root}/tests/test-routing-mode-required.sh"
"${repo_root}/tests/test-policy-firewall.sh"
"${repo_root}/tests/test-core-nat-eth0.sh"
