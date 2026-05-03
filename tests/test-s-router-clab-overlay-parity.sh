#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-test-three-site" "${tmp_dir}"
topology="${tmp_dir}/fabric.clab.yml"

assert_topology_contains "${topology}" "esp0xdeadbeef-site-a-s-router-core-nebula:"
assert_topology_contains "${topology}" "espbranch-site-b-b-router-core-nebula:"
assert_topology_contains "${topology}" "esp0xdeadbeef-site-c-c-router-nebula-core:"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10.10.0.0/32 via 10.50.0.13 dev eth3 onlink"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10.10.0.0/32 via 10.50.0.17 dev eth5 onlink"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-c-c-router-policy" \
  "ip route replace 10.10.0.0/32 via 10.80.0.29 dev eth8 onlink"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip addr replace 100.96.10.1/32 dev eth4"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip route replace 100.96.10.2/32 dev eth4"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip route replace 10.60.10.0/24 via 100.96.10.2 dev eth4 onlink"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip addr replace 100.96.10.2/32 dev eth3"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip route replace 100.96.10.1/32 dev eth3"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip route replace 10.20.10.0/24 via 100.96.10.1 dev eth3 onlink"

assert_topology_contains "${topology}" "esp0xdeadbeef-site-a-s-router-core-nebula:eth4"
assert_topology_contains "${topology}" "espbranch-site-b-b-router-core-nebula:eth3"
assert_topology_contains "${topology}" "clab.link.type: overlay"
assert_topology_contains "${topology}" "clab.overlay: east-west"

pass "s-router-clab-overlay-parity"
