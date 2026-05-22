#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "single-wan-with-nebula" "${tmp_dir}"

topology="${tmp_dir}/fabric.clab.yml"
node="esp0xdeadbeef-site-a-s-router-core-nebula"
overlay_addr="100.96.10.1/32"

overlay_dev="$(
  grep -E "ip addr replace ${overlay_addr} dev eth[0-9]+" "${topology}" \
    | sed -E 's/.* dev (eth[0-9]+).*/\1/' \
    | head -n1
)"

if [[ -z "${overlay_dev}" ]]; then
  echo "FAIL single overlay interface link: missing overlay runtime address ${overlay_addr}" >&2
  exit 1
fi

if ! grep -Fq "${node}:${overlay_dev}" "${topology}"; then
  echo "FAIL single overlay interface link: overlay runtime ${overlay_dev} is not materialized as a Containerlab link" >&2
  exit 1
fi

if ! awk -v endpoint="${node}:${overlay_dev}" '
  $0 ~ "^[[:space:]]*- " endpoint "$" { in_link = 1; next }
  in_link && $0 ~ "clab.link.type: overlay" { found_type = 1 }
  in_link && $0 ~ "clab.overlay: nebula" { found_overlay = 1 }
  in_link && $0 ~ "^[[:space:]]*- endpoints:" { in_link = 0 }
  END { exit(found_type && found_overlay ? 0 : 1) }
' "${topology}"; then
  echo "FAIL single overlay interface link: ${node}:${overlay_dev} is not marked as a Nebula overlay link" >&2
  exit 1
fi

echo "PASS single-overlay-interface-link"
