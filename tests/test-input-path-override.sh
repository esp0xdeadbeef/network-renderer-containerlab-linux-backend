#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/input-path.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

NETWORK_INPUT_PATH_NETWORK_LABS="${tmp_dir}" resolved="$(resolve_input_path network-labs)"
if [[ "${resolved}" != "${tmp_dir}" ]]; then
  echo "input path override did not resolve network-labs" >&2
  exit 1
fi

if NETWORK_INPUT_PATH_NETWORK_LABS="${tmp_dir}/missing" resolve_input_path network-labs >/dev/null 2>&1; then
  echo "input path override accepted a missing directory" >&2
  exit 1
fi

echo "PASS input-path-override"
