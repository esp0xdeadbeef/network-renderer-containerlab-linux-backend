#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

removed_cm_files=(
  access_firewall.py
  firewall_core.py
  node_context.py
  node_renderer.py
  upstream_selector_firewall.py
)

for file_name in "${removed_cm_files[@]}"; do
  if [[ -e "${repo_root}/clabgen/s88/CM/${file_name}" ]]; then
    echo "untraced CM stub must not exist: clabgen/s88/CM/${file_name}" >&2
    exit 1
  fi
done

if rg -n 'access_firewall|firewall_core|node_context|node_renderer|upstream_selector_firewall|render_node_exec|build_node_context' \
  "${repo_root}/clabgen" "${repo_root}/tests" \
  -g '!test-s88-no-untraced-cm-stubs.sh' >&2
then
  echo "removed untraced CM stub is still referenced" >&2
  exit 1
fi

echo "PASS s88-no-untraced-cm-stubs"
