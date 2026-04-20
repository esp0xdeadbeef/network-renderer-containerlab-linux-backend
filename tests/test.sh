#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/tests/test-passing-fixtures.sh"
"${repo_root}/tests/test-policy-firewall.sh"
