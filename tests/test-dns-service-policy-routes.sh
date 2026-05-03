#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-test-three-site" "${tmp_dir}"
topology="${tmp_dir}/fabric.clab.yml"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10.20.10.0/24 via 10.50.0.13 dev eth3 onlink"

assert_node_contains \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10.20.10.0/24 via 10.50.0.17 dev eth5 onlink"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-upstream-selector" \
  "ip route replace 10.20.10.0/24 via 10.10.0.44 dev eth13 onlink"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-policy-only" \
  "ip route replace 10.20.10.0/24 via 10.10.0.24 dev eth5 onlink"

assert_node_contains \
  "${topology}" \
  "esp0xdeadbeef-site-c-c-router-policy" \
  "ip route replace 10.90.20.0/24 via 10.80.0.14 dev eth2 onlink"

assert_topology_contains \
  "${topology}" \
  "udp dport 53 counter accept"

assert_topology_contains \
  "${topology}" \
  "tcp dport 53 counter accept"

assert_topology_absent \
  "${topology}" \
  "ip route replace 10.50.0.0 via 10.50.0.16"

pass "dns-service-policy-routes"
