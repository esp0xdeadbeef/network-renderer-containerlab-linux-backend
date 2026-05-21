#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/render-clab-example.sh"
source "${repo_root}/tests/lib/clab-yaml.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_clab_example "s-router-overlay-dns-lane-policy" "${tmp_dir}"
topology="${tmp_dir}/fabric.clab.yml"

assert_topology_contains "${topology}" "esp0xdeadbeef-site-a-s-router-core-nebula:"
assert_topology_contains "${topology}" "espbranch-site-b-b-router-core-nebula:"
assert_topology_contains "${topology}" "esp0xdeadbeef-site-c-c-router-nebula-core:"

assert_node_exec \
  matches \
  "${topology}" \
  "espbranch-site-b-b-router-policy" \
  "ip route replace 10\\.20\\.10\\.0/24 nexthop via 10\\.50\\.0\\.13 dev eth3 onlink\\s+nexthop\\s+via 10\\.50\\.0\\.17 dev eth5 onlink"

assert_node_exec \
  matches \
  "${topology}" \
  "esp0xdeadbeef-site-c-c-router-policy" \
  "ip route replace 10\\.20\\.10\\.0/24 nexthop via 10\\.80\\.0\\.13 dev eth3 onlink\\s+nexthop\\s+via 10\\.80\\.0\\.17 dev eth5 onlink"

assert_node_matches \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip addr replace 100\\.96\\.10\\.1/32 dev eth[0-9]+"

assert_node_matches \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip route replace 100\\.96\\.10\\.2/32 dev eth[0-9]+"

assert_node_matches \
  "${topology}" \
  "esp0xdeadbeef-site-a-s-router-core-nebula" \
  "ip route replace 10\\.60\\.10\\.0/24 via 100\\.96\\.10\\.2 dev eth[0-9]+ onlink"

assert_node_matches \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip addr replace 100\\.96\\.10\\.2/32 dev eth[0-9]+"

assert_node_matches \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip route replace 100\\.96\\.10\\.1/32 dev eth[0-9]+"

assert_node_matches \
  "${topology}" \
  "espbranch-site-b-b-router-core-nebula" \
  "ip route replace 10\\.20\\.10\\.0/24 via 100\\.96\\.10\\.1 dev eth[0-9]+ onlink"

assert_topology_contains "${topology}" "esp0xdeadbeef-site-a-s-router-core-nebula:eth"
assert_topology_contains "${topology}" "espbranch-site-b-b-router-core-nebula:eth"
assert_topology_contains "${topology}" "clab.link.type: overlay"
assert_topology_contains "${topology}" "clab.overlay: east-west"

if grep -A4 -E 's-router-core-nebula:eth|b-router-core-nebula:eth' "${topology}" | grep -q 'clab.link.bridge: br-uplink'; then
  echo "core-nebula overlay nodes must not attach directly to host WAN/uplink bridges" >&2
  exit 1
fi

pass "s-router-clab-overlay-parity"
