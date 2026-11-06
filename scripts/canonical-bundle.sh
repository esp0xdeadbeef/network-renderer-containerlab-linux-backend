#!/usr/bin/env bash
# Canonical renderer-input helper.
#
# FS-310-HDS-040-SDS-010-SMS-100: renderers consume one validated canonical
# realization bundle. Pipeline tests build the upstream chain themselves and then
# hand the renderer the released bundle, never a raw CPM payload.
set -euo pipefail

# emit_canonical_bundle <cpm.json> <bundle.json> [scope-identity]
emit_canonical_bundle() {
  local cpm_json="$1"
  local bundle_out="$2"
  local scope="${3:-clab-renderer-input}"
  local repo="${SMS_TEST_REPO_ROOT:-${repo_root:-$(git rev-parse --show-toplevel)}}"

  REPO_ROOT="${repo}" CPM_JSON="${cpm_json}" SCOPE="${scope}" \
    nix eval --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        cpm = builtins.fromJSON (builtins.readFile (builtins.getEnv "CPM_JSON"));
        scope = builtins.getEnv "SCOPE";
        artifact = {
          kind = "network-control-plane-artifact";
          artifactIdentity = "${scope}-cpm";
          artifactDigest = builtins.hashString "sha256" (builtins.toJSON cpm.control_plane_model);
          inherit (cpm) control_plane_model;
        };
        realization = flake.inputs.network-realization-model;
      in
        realization.lib.realize {
          input = artifact;
          requestScope = {
            kind = "complete-artifact";
            identity = scope;
          };
          rootLockIdentity = "network-renderer-clab-flake-lock";
          producerRevision = realization.rev or "unknown";
        }
    ' >"${bundle_out}"
}

# CLI: canonical-bundle.sh <cpm.json> <bundle.json> [scope]
# Used by focused renderer tests (Python) that build a CPM fixture themselves:
# SMS-100 permits a schema-valid canonical fixture, and the release stamp is
# produced by network-realization-model, never fabricated by the test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -ge 2 ]] || { echo "usage: $0 <cpm.json> <bundle.json> [scope]" >&2; exit 2; }
  emit_canonical_bundle "$1" "$2" "${3:-clab-renderer-input}"
fi

# CLI: canonical-bundle.sh <cpm.json> <bundle.json> [scope]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -ge 2 ]] || { echo "usage: $0 <cpm.json> <bundle.json> [scope]" >&2; exit 2; }
  emit_canonical_bundle "$1" "$2" "${3:-clab-renderer-input}"
fi
