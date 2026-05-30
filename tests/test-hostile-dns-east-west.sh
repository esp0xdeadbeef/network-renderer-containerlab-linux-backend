#!/usr/bin/env bash
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-015
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-overlay-dns-lane-policy" "${tmp_dir}"
topology="${tmp_dir}/fabric.clab.yml"

assert_node_matches \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10\\.20\\.10\\.0/24 nexthop via 10\\.50\\.0\\.13 dev up-branch-ew onlink\\s+nexthop via 10\\.50\\.0\\.17 dev up-hostile-ew onlink"

assert_node_matches \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip -6 route replace fd42:dead:beef:10::/64 nexthop via fd42:dead:feed:1000:0:0:0:d\\s+dev up-branch-ew onlink nexthop via fd42:dead:feed:1000:0:0:0:11 dev up-hostile-ew\\s+onlink"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-access-hostile" \
  "ip addr replace 10.70.10.1/24 dev tenant-hostile"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-access-hostile" \
  "ip -6 addr replace fd42:dead:feed:70::1/64 dev tenant-hostile"

pass "hostile-dns-east-west"
