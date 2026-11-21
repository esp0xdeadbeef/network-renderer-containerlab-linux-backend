#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-060
# GAMP-SCOPE: software-module-test
set -euo pipefail

# One route authority, one next-hop set — asserted on the emitted topology.
#
# URS "Canonical Realization and Renderer Boundary": a platform binding shall
# not create or duplicate routing. FS-310-HDS-020-SDS-010-SMS-060: "One
# route-selection authority shall have one modeled semantic next-hop set.
# Different next-hop sets for the same authority shall fail unless explicit
# multipath policy names the complete authorized member set," and its
# Construction Handoff names this renderer class explicitly: "network-renderer-
# nixos and the CLAB renderer shall consume the same canonical records and emit
# equivalent route cardinality and failure behavior."
#
# Authority here is (node, table, destination) as it reaches the emitted
# startup configuration. Two `ip route replace` commands for one tuple mean the
# second silently evicts the first, so which next hop survives depends on
# emission order — the same failure that cost a live router its IPv6 exit on
# 2026-11-21.
#
# Harness guards, so a broken extraction cannot masquerade as a finding:
#   * the topology file must exist and be non-empty;
#   * at least one route primitive must be found, else the clause is vacuous.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
trace_id="FS-310-HDS-020-SDS-010-SMS-060"

source "${repo_root}/tests/lib/render-clab-example.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_log="${tmp_dir}/render.log"
render_rc=0
render_clab_example single-wan "${tmp_dir}" >"${render_log}" 2>&1 || render_rc=$?

# This renderer already implements SMS-060: it refuses a destination that
# reaches it with more than one next hop and no multipath authority, naming this
# trace id. When that happens the site cannot be realized at all, so it is a
# FAILURE of the property under test -- reported here with the renderer own
# diagnostic rather than as a silent absence of output.
if grep -q "conflicting-next-hop" "${render_log}"; then
  printf 'FAIL %s: the bundle presents one route authority with several next hops; this renderer correctly refused it\n' "${trace_id}" >&2
  grep "conflicting-next-hop" "${render_log}" | sed "s/^/  /" >&2
  printf '  SMS-060: different next-hop sets for one authority shall fail unless an explicit multipath contract names the member set.\n' >&2
  exit 1
fi

if [[ "${render_rc}" != "0" ]]; then
  printf 'FAIL %s: harness error -- rendering the example failed for an unrelated reason\n' "${trace_id}" >&2
  tail -20 "${render_log}" | sed "s/^/  /" >&2
  exit 1
fi

topology="${tmp_dir}/fabric.clab.yml"

if [[ ! -s "${topology}" ]]; then
  printf 'FAIL %s: harness error -- the render produced no topology file\n' "${trace_id}" >&2
  exit 1
fi

# Extract `<node>|<table>|<destination>|<rest-of-command>` for every route
# command. Node context comes from the YAML node key (four-space indent); a
# route line is any `ip route replace` / `ip -6 route replace`.
routes="${tmp_dir}/routes.txt"
awk '
  /^    [A-Za-z0-9_.-]+:[[:space:]]*$/ { node = $0; sub(/^ +/, "", node); sub(/:.*/, "", node); next }
  /ip (-6 )?route (replace|add) / {
    line = $0
    while (match(line, /ip (-6 )?route (replace|add) /)) {
      rest = substr(line, RSTART + RLENGTH)
      sub(/["\047].*$/, "", rest)
      table = "main"
      if (match(rest, /table [0-9]+/)) { table = substr(rest, RSTART + 6, RLENGTH - 6) }
      dst = rest
      sub(/ .*/, "", dst)
      print node "|" table "|" dst "|" rest
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "${topology}" >"${routes}"

route_count="$(wc -l <"${routes}" | tr -d ' ')"
if [[ "${route_count}" == "0" ]]; then
  printf 'FAIL %s: harness error -- the topology carries no route primitive, so the clause is vacuous\n' "${trace_id}" >&2
  exit 1
fi

# One authority with two different next-hop commands is the failure.
duplicates="$(awk -F'|' '
  { key = $1 "|" $2 "|" $3
    rest = $4
    if (!(key in seen)) { seen[key] = rest; next }
    if (seen[key] != rest) { dup[key] = seen[key] "  ||  " rest }
  }
  END { for (k in dup) print k "  -> " dup[k] }
' "${routes}" | sort)"

if [[ -n "${duplicates}" ]]; then
  printf 'FAIL %s: one route authority is emitted twice with different next hops\n' "${trace_id}" >&2
  while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${duplicates}"
  printf '  SMS-060: one authority, one next-hop set; "ip route replace" keys on (table, destination).\n' >&2
  exit 1
fi

printf 'PASS %s (%s route primitive(s) across the topology, every (node, table, destination) emitted once)\n' \
  "${trace_id}" "${route_count}"
