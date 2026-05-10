#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-overlay-dns-lane-policy" "${tmp_dir}"
topology="${tmp_dir}/fabric.clab.yml"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-access-hostile" \
  "ip -6 addr replace fd42:dead:feed:70::1/64 dev eth2"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip -6 route replace fd42:dead:feed:70::/64 via fd42:dead:feed:1000:0:0:0:5"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip -6 route replace fd42:dead:feed:70::/64 via fd42:dead:feed:1000:0:0:0:a"

assert_topology_absent "${topology}" "2a01:4f8:1c17:b337"
assert_topology_absent "${topology}" "access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"

pass "hostile-gua-advertisements"
