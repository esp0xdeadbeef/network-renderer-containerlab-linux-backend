#!/usr/bin/env bash
# GAMP-ID: FS-840 (functional requirement: scoped runtime secret delivery)
# GAMP-SCOPE: software-module-test
# Focused construction test: CLAB renderer sops service ordering.
#
# FS-840: "Required material that is missing, stale, mismatched, unauthorized,
# or ambiguous shall fail visibly before the consuming service is treated as ready."
#
# Verifies that s-router-clab-render-live.service waits for sops-nix.service
# before deploying containerlab topology.
#
# Active seeded negatives:
#   SN1 — construct a host-module fragment where s-router-clab-render-live
#          has NO sops-nix.service in after; verify scanner detects the gap
#   SN2 — construct a fragment with oneshot sops decrypt service; verify
#          scanner detects the SMS-070 violation
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "--- FS-840: CLAB renderer sops service ordering ---"
echo ""

failures=0

# ============================================================
# Check 1: s-router-clab-render-live.service has sops-nix.service after
# ============================================================
echo "--- Check 1: s-router-clab-render-live waits for sops-nix.service ---"

# Find the service definition block and verify it has sops ordering
if grep -A10 'systemd.services.s-router-clab-render-live' "${repo_root}/host-module.nix" 2>/dev/null | \
   grep -q 'sops-nix.service'; then
  echo "  PASS: s-router-clab-render-live.service has sops-nix.service in after"
else
  echo "  FAIL: s-router-clab-render-live.service missing sops-nix.service ordering"
  failures=$((failures + 1))
fi

# Also verify the service definition exists
if grep -q 'systemd.services.s-router-clab-render-live' "${repo_root}/host-module.nix" 2>/dev/null; then
  echo "  PASS: s-router-clab-render-live service definition exists"
else
  echo "  FAIL: s-router-clab-render-live service definition not found"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 2: No oneshot secret services in the CLAB renderer
# ============================================================
echo "--- Check 2: No oneshot secret-materialization services ---"

oneshot_hits=$(grep -rn 'sops -d\|ln -sf.*secrets\|writeShellScript.*secrets\|ExecStart.*secrets' \
  "${repo_root}/" --include='*.nix' 2>/dev/null || true)

if [[ -z "${oneshot_hits}" ]]; then
  echo "  PASS: No oneshot secret services detected"
else
  echo "  FAIL: Oneshot secret service(s) found:"
  echo "${oneshot_hits}"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 3 (SN1): Scanner detects missing sops-nix.service
# ============================================================
echo "--- Check 3 (SN1): Scanner detects missing sops ordering ---"

injected_file="${tmp_dir}/injected-clab-service.nix"
cat > "${injected_file}" <<'NIX'
{ lib, ... }:
{
  systemd.services.s-router-clab-render-live = lib.mkIf true {
    description = "Render and deploy the s-router Containerlab topology";
    wantedBy = [ "multi-user.target" ];
    # VIOLATION: missing sops-nix.service — fabric containers may start before secrets ready
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "docker.service" "network-online.target" ];
    serviceConfig.Type = "oneshot";
  };
}
NIX

# Scan: the injected service has container-related services but no sops-nix
has_sops_after=$(grep -c 'after.*sops-nix.service' "${injected_file}" 2>/dev/null || true)
has_clab_service=$(grep -c 's-router-clab-render-live' "${injected_file}" 2>/dev/null || true)

if [[ "${has_clab_service:-0}" -gt 0 ]] && [[ "${has_sops_after:-0}" -eq 0 ]]; then
  echo "  PASS SN1: Scanner correctly identifies s-router-clab-render-live missing sops-nix"
else
  echo "  FAIL SN1: Scanner did not detect missing sops-nix ordering"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 4 (SN2): Scanner detects oneshot secret service
# ============================================================
echo "--- Check 4 (SN2): Scanner detects injected oneshot secret service ---"

injected_file2="${tmp_dir}/injected-clab-oneshot.nix"
cat > "${injected_file2}" <<'NIX'
{ pkgs, ... }:
{
  # VIOLATION: oneshot service that decrypts secrets — prohibited by SMS-070
  systemd.services.clab-pppoe-secrets = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecStart = pkgs.writeShellScript "clab-pppoe-init" ''
      mkdir -p /run/secrets
      sops -d /etc/clab/pppoe-creds.enc > /run/secrets/pppoe-creds
      chmod 600 /run/secrets/pppoe-creds
    '';
  };
}
NIX

if grep -qE '(sops -d|ln -sf.*secrets|writeShellScript.*secrets|ExecStart.*secrets)' "${injected_file2}"; then
  echo "  PASS SN2: Scanner detects oneshot sops-decrypt service in injected violation"
else
  echo "  FAIL SN2: Scanner did NOT detect oneshot secret service"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Result
# ============================================================
if [[ ${failures} -eq 0 ]]; then
  echo "PASS FS-840 — CLAB renderer sops service ordering verified"
  exit 0
else
  echo "FAIL FS-840: ${failures} failure(s)"
  exit 1
fi
