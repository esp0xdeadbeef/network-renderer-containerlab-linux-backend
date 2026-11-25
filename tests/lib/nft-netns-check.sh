#!/usr/bin/env bash
# GAMP-SCOPE: test helper (not a case; not discovered as one)
#
# Run `nft -c -f <ruleset>` inside a throwaway network namespace.
#
# Two construction cases validate rendered nftables by handing the batch back to
# nft itself -- the only authority on whether the renderer's output is a ruleset
# and not a plausible-looking string:
#
#   FS-270-HDS-010-SDS-010-SMS-020  fs270-policy.nft
#   FS-230-HDS-010-SDS-010-SMS-040  runtime-nft-batch.nft
#
# `nft -c` cannot run unprivileged: it opens a netlink socket and fails with
# "netlink: Error: cache initialization failed: Operation not permitted" (measured,
# as a normal user, with the nftables from this flake). So the check needs a
# namespace that gives it CAP_NET_ADMIN over a ruleset nobody else can see.
#
# Which namespace is available is a property of the host, not of the ruleset:
#
#   * `unshare -Urn` — an unprivileged user+network namespace. This is what a
#     workstation with apparmor_restrict_unprivileged_userns=0 gives you, and what
#     these cases used unconditionally.
#   * `sudo -n unshare -n` — a plain network namespace as root. A GitHub-hosted
#     ubuntu-26.04 runner restricts unprivileged user namespaces, so the first form
#     dies before nft is reached and the case is red with nothing wrong in it:
#
#       unshare: write failed /proc/self/uid_map: Operation not permitted
#
#     That is the whole of run 45519809169's failure: both cases printed their own
#     PASS line first and then failed on this line.
#
# Both branches run the same `nft -c -f`; neither skips the check, and a host that
# offers neither is a hard failure rather than a pass.
#
# Usage (the caller supplies nft on PATH, typically via `nix shell ... --command`):
#
#   bash tests/lib/nft-netns-check.sh <nft-ruleset-file>
set -uo pipefail

nft_check_in_netns() {
  local file="${1:-}"
  if [[ -z "${file}" ]]; then
    printf 'usage: %s <nft-ruleset-file>\n' "$(basename "${BASH_SOURCE[0]}")" >&2
    return 2
  fi
  [[ -f "${file}" ]] || {
    printf 'nft-netns-check: no such ruleset: %s\n' "${file}" >&2
    return 2
  }

  local nft
  nft="$(command -v nft)" || {
    printf 'nft-netns-check: nft is not on PATH\n' >&2
    return 1
  }

  local userns_error
  if userns_error="$(unshare -Urn true 2>&1)"; then
    unshare -Urn "${nft}" -c -f "${file}"
    return
  fi

  local rootns_error
  if rootns_error="$(sudo -n unshare -n true 2>&1)"; then
    sudo -n unshare -n "${nft}" -c -f "${file}"
    return
  fi

  cat >&2 <<EOF
nft-netns-check: this host gives the check no network namespace, so 'nft -c -f ${file}'
cannot run. That is an environment failure, not a verdict on the ruleset.
  unshare -Urn: ${userns_error}
  sudo -n unshare -n: ${rootns_error}
EOF
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  nft_check_in_netns "$@"
fi
