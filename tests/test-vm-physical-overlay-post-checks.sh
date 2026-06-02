#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checks="${repo_root}/tests/lib/vm-example-checks.sh"

extract_function() {
  local name="$1"
  awk -v name="${name}" '
    $0 == name "()" " {" { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { exit }
  ' "${checks}"
}

for fn in check_dual_wan_overlay check_dual_wan_overlay_bgp; do
  body="$(extract_function "${fn}")"
  if grep -q 'ping -c1' <<<"${body}"; then
    echo "FAIL vm-physical-overlay-post-checks: ${fn} must not require underlay ICMP in physical-uplink CLAB examples" >&2
    exit 1
  fi
  if ! grep -q 'ip route get' <<<"${body}"; then
    echo "FAIL vm-physical-overlay-post-checks: ${fn} must prove kernel route selection" >&2
    exit 1
  fi
done

for fn in check_single_wan check_site_a_wan_core_egress; do
  body="$(extract_function "${fn}")"
  if grep -q 'addr show dev eth2' <<<"${body}"; then
    echo "FAIL vm-physical-overlay-post-checks: ${fn} must not hard-code eth2 for VM WAN egress checks" >&2
    exit 1
  fi
  if ! grep -q 'egress_dev=' <<<"${body}"; then
    echo "FAIL vm-physical-overlay-post-checks: ${fn} must derive the WAN egress device from route selection" >&2
    exit 1
  fi
done

echo "PASS vm-physical-overlay-post-checks"
