#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "single-wan-with-nebula" "${tmp_dir}"

topology="${tmp_dir}/fabric.clab.yml"

if ! grep -Fq "ip addr replace 100.96.10.1/32 dev eth3" "${topology}"; then
  echo "FAIL single overlay interface link: expected overlay runtime on eth3" >&2
  exit 1
fi

if ! grep -Fq "esp0xdeadbeef-site-a-s-router-core-nebula:eth3" "${topology}"; then
  echo "FAIL single overlay interface link: overlay runtime eth3 is not materialized as a Containerlab link" >&2
  exit 1
fi

echo "PASS single-overlay-interface-link"
