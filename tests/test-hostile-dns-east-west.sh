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
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10.20.10.0/24 via 10.50.0.17 dev eth5 onlink"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip -6 route replace fd42:dead:beef:10::/64 via fd42:dead:feed:1000:0:0:0:11"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-access-hostile" \
  "ip addr replace 10.70.10.1/24 dev eth2"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-access-hostile" \
  "ip -6 addr replace fd42:dead:feed:70::1/64 dev eth2"

pass "hostile-dns-east-west"
