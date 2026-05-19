#!/usr/bin/env bash
set -euo pipefail

require_text() {
  local label="$1"
  local file="$2"
  local needle="$3"

  grep -Fq -- "$needle" "$file" || fail "FAIL ${label}: missing output contract text: ${needle}"
}

require_regex() {
  local label="$1"
  local file="$2"
  local regex="$3"

  grep -Eq -- "$regex" "$file" || fail "FAIL ${label}: missing output contract regex: ${regex}"
}

forbid_text() {
  local label="$1"
  local file="$2"
  local needle="$3"

  if grep -Fq -- "$needle" "$file"; then
    fail "FAIL ${label}: forbidden output contract text present: ${needle}"
  fi
}

assert_clab_example_output_contract() {
  local label="$1"
  local topology="$2"
  local bridges="$3"

  require_regex "$label" "$topology" 'nft add table inet (filter|clab_guard)'
  require_regex "$label" "$topology" 'ip route replace|router bgp'
  forbid_text "$label" "$topology" "access-node-ipv6-prefix-"

  case "$label" in
    *bgp*)
      require_text "$label" "$topology" "router bgp"
      ;;
  esac

  case "$label" in
    *overlay*|tri-site-*)
      require_text "$label" "$topology" "clab.link.type: overlay"
      require_regex "$label" "$topology" 'core-nebula|nebula-core'
      ;;
  esac

  case "$label" in
    single-wan-with-nebula)
      require_text "$label" "$topology" "esp0xdeadbeef-site-a-s-router-core-nebula"
      require_regex "$label" "$topology" 'clab\.link\.bridge: br-[0-9a-f]{12}'
      require_regex "$label" "$topology" 'core-nebula|nebula-core'
      ;;
  esac

  case "$label" in
    *dns-lane-policy|tri-site-*)
      require_text "$label" "$topology" "udp dport 53"
      require_text "$label" "$topology" "tcp dport 53"
      ;;
  esac

  case "$label" in
    *ipv6-pd*|ipv6-pd-*)
      require_text "$label" "$topology" "ip -6 route replace"
      require_regex "$label" "$topology" 'radvd|accept_ra=2|ip6 saddr'
      ;;
  esac

  case "$label" in
    single-wan-vlan-trunk-lanes)
      require_text "$label" "$topology" "clab.link.bridge: br-trunk"
      require_text "$label" "$topology" "clab.link.bridge: tr100"
      require_text "$label" "$topology" "clab.link.bridge: tr202"
      require_regex "$label" "$bridges" '"mode"[[:space:]]*:[[:space:]]*"trunk"'
      require_regex "$label" "$bridges" '"parent"[[:space:]]*:[[:space:]]*"eno1"'
      ;;
  esac

  case "$label" in
    single-wan-uplink-ebgp)
      require_text "$label" "$topology" "neighbor 203.0.113.1 remote-as 64512"
      ;;
    single-wan-uplink-static-egress)
      require_text "$label" "$topology" "ip route replace default via 192.0.2.1"
      ;;
    s-router-public-overlay-service)
      require_text "$label" "$topology" "udp dport 4242"
      require_text "$label" "$topology" "tcp dport 4242"
      ;;
  esac
}
