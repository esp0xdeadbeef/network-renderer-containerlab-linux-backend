#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${repo_root}/clabgen/s88/site/access_tenants.py"

if rg -n -e 're\\.split' -e 'node_name_candidate' -e 'candidate.*node\\.name' "${target}" >/tmp/clab-access-tenant-node-name-parsing.txt; then
  cat /tmp/clab-access-tenant-node-name-parsing.txt >&2
  echo "FAIL access-tenant-no-node-name-parsing: access tenant identity must come from explicit CPM interface tenant data" >&2
  exit 1
fi

echo "PASS access-tenant-no-node-name-parsing"
