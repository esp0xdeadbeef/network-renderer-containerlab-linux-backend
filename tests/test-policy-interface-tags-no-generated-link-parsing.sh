#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${repo_root}/clabgen/s88/site/interface_tags.py"

if rg -n -F -e '--access-' -e '--uplink-' -e 'split(' -e 'rsplit(' "${target}" >/tmp/clab-policy-interface-tag-link-parsing.txt; then
  cat /tmp/clab-policy-interface-tag-link-parsing.txt >&2
  echo "FAIL policy-interface-tags-no-generated-link-parsing: CLAB policy interface tags must use CPM lane metadata, not generated p2p names" >&2
  exit 1
fi

echo "PASS policy-interface-tags-no-generated-link-parsing"
