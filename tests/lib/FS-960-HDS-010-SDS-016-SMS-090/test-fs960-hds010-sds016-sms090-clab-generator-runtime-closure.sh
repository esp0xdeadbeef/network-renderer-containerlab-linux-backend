#!/usr/bin/env bash
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
host_module="${repo_root}/host-module.nix"
flake="${repo_root}/flake.nix"

fail() {
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-090: $*" >&2
  exit 1
}

grep -Fq "containerlabLinuxGenerateClabConfig" "${flake}" \
  || fail "flake hostModule must pass generate-clab-config package into the host module"
grep -Fq "self.packages.\${pkgs.system}.generate-clab-config" "${flake}" \
  || fail "flake hostModule must bind the generator package for the target system"
grep -Fq "containerlabLinuxGenerateClabConfig ? null" "${host_module}" \
  || fail "host module must accept the generator package as an explicit module argument"
grep -Fq "\${generateClabConfig}/bin/generate-clab-config" "${host_module}" \
  || fail "runtime service must execute the generator package from the system closure"

if grep -Fq 'nix run --show-trace "path:$renderer_repo#generate-clab-config"' "${host_module}"; then
  fail "runtime service must not call nix run for generate-clab-config"
fi
if grep -Eq 'pkgs\.nix([[:space:]]|$)' "${host_module}"; then
  fail "s-router-clab-render-live runtimeInputs must not include pkgs.nix for generator execution"
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-090"
