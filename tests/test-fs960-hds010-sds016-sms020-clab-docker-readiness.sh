#!/usr/bin/env bash
# GAMP-ID: FS-960-HDS-010-SDS-016-SMS-020
# GAMP-SCOPE: software-module-test (CMC focused test)
# Tests CLAB Docker/VM tooling readiness: pinned base image, FRR binaries,
# tooling package commands, build/save/verify ordering, and cache evidence
# JSON emission. Validates the Dockerfile, build.sh, and VM runner together.
# Non-destructive: read-only grep checks on source files.
#
# SMS-020 Acceptance Predicates:
#  1. Docker wait/readiness in VM runner (run-in-vm.sh)
#  2. FRR tooling base image pinned by digest
#  3. FRR binaries present (staticd, bgpd, zebra)
#  4. Tooling packages present (tcpdump, ping, traceroute, curl, etc.)
#  5. Build/save/verify ordering: verify after build, before save
#  6. No Alpine packages (must use Debian PPP path)
#  7. Cache evidence JSON schema in build script
#  8. update-repo-cache-with-vm.sh contract checks
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/run-in-vm.sh"
dockerfile="${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
build_script="${repo_root}/docker-clab-frr-plus-tooling/build.sh"

failures=0

# ---------------------------------------------------------------------------
# Test 1: VM runner Docker readiness
# ---------------------------------------------------------------------------
if grep -q 'docker_wait_seconds=' "${script}" &&
   grep -q 'wait_for_docker()' "${script}" &&
   grep -q 'systemctl start docker' "${script}" &&
   grep -q 'docker_cmd.* info' "${script}" &&
   grep -q 'docker did not become ready' "${script}"; then
  echo "PASS test1: VM runner Docker readiness"
else
  echo "FAIL test1: VM runner Docker readiness" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 2: FRR tooling base image pinned by digest
# ---------------------------------------------------------------------------
if grep -q 'debian:bookworm-slim@sha256:' "${dockerfile}" &&
   grep -q 'debian:bookworm-slim@sha256:' "${build_script}"; then
  echo "PASS test2: FRR tooling base image pinned by digest"
else
  echo "FAIL test2: FRR tooling base image not pinned by digest" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 3: Build script tooling verification and cache evidence
# ---------------------------------------------------------------------------
if grep -q 'verify_tooling_image()' "${build_script}" &&
   grep -q 'docker run --rm --entrypoint /bin/sh "$IMAGE"' "${build_script}" &&
   grep -q 'docker load -i "${CACHE_TAR}"' "${build_script}" &&
   grep -q -- '--pull=false' "${build_script}" &&
   grep -q -- '--label "${LABEL_KEY}=${CACHE_KEY}"' "${build_script}" &&
   grep -q 'docker save "$IMAGE" -o "${CACHE_TAR}"' "${build_script}" &&
   grep -q 'CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON' "${build_script}"; then
  echo "PASS test3: build script tooling verification and cache pipeline"
else
  echo "FAIL test3: build script missing tooling verification or cache pipeline" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 4: Cache evidence JSON schema
# ---------------------------------------------------------------------------
if grep -q '"schema": "clab-frr-tooling-cache-evidence.v1",' "${build_script}" &&
   grep -q '"cachePresentAtStart": bool_env("CACHE_PRESENT_AT_START")' "${build_script}" &&
   grep -q '"cacheLoaded": bool_env("CACHE_LOADED")' "${build_script}" &&
   grep -q '"imageBuilt": bool_env("CACHE_BUILT")' "${build_script}"; then
  echo "PASS test4: cache evidence JSON schema emits all required fields"
else
  echo "FAIL test4: cache evidence JSON schema incomplete" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 5: Dockerfile tooling packages
# ---------------------------------------------------------------------------
if grep -q 'apt-get install -y --no-install-recommends' "${dockerfile}" &&
   grep -q 'rm -rf /var/lib/apt/lists/' "${dockerfile}" &&
   grep -q 'ripgrep' "${dockerfile}" &&
   grep -q 'nmap' "${dockerfile}"; then
  echo "PASS test5: Dockerfile has apt-get cleanup and tooling packages"
else
  echo "FAIL test5: Dockerfile missing tooling packages or apt cleanup" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 6: FRR binaries present in Dockerfile and build script
# ---------------------------------------------------------------------------
if grep -q 'test -x /usr/lib/frr/staticd' "${dockerfile}" &&
   grep -q 'test -x /usr/lib/frr/staticd' "${build_script}" &&
   grep -q 'test -x /usr/lib/frr/bgpd' "${dockerfile}" &&
   grep -q 'test -x /usr/lib/frr/bgpd' "${build_script}" &&
   grep -q 'test -x /usr/lib/frr/zebra' "${dockerfile}" &&
   grep -q 'test -x /usr/lib/frr/zebra' "${build_script}"; then
  echo "PASS test6: FRR binaries (staticd, bgpd, zebra) verified"
else
  echo "FAIL test6: FRR binary verification incomplete" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 7: Tooling package commands (17 tools)
# ---------------------------------------------------------------------------
tooling_ok=1
for command_name in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff udhcpc udhcpd vtysh python3; do
  if ! grep -q 'command -v "$cmd"' "${build_script}"; then
    echo "FAIL test7: build script must verify 'command -v' for package commands before cache export" >&2
    tooling_ok=0
    break
  fi
  if ! grep -q "${command_name}" "${dockerfile}" && ! grep -q "${command_name}" "${build_script}"; then
    echo "FAIL test7: FRR tooling package command ${command_name} must be present in Dockerfile or builder verification" >&2
    tooling_ok=0
    break
  fi
done
if (( tooling_ok == 1 )); then
  echo "PASS test7: all 17 tooling package commands verified"
else
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 8: Build/save/verify ordering (verify after build, before save)
# ---------------------------------------------------------------------------
build_line="$(grep -n 'docker build' "${build_script}" | head -n1 | cut -d: -f1)"
save_line="$(grep -n 'docker save "$IMAGE" -o "${CACHE_TAR}"' "${build_script}" | head -n1 | cut -d: -f1)"
verify_line="$(
  awk -v build="${build_line}" -v save="${save_line}" '
    NR > build && NR < save && /verify_tooling_image/ { print NR; exit }
  ' "${build_script}"
)"
if [[ -n "${build_line}" && -n "${verify_line}" && -n "${save_line}" &&
      "${build_line}" -lt "${verify_line}" && "${verify_line}" -lt "${save_line}" ]]; then
  echo "PASS test8: build → verify → save ordering correct"
else
  echo "FAIL test8: FRR tooling builder must verify package commands after build and before cache save" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 9 (seeded negative): No unpinned base images
# ---------------------------------------------------------------------------
if grep -qE 'frrouting/frr:latest|debian:latest|bookworm-slim($|")' "${dockerfile}" "${build_script}"; then
  echo "FAIL test9: FRR tooling base image must be pinned by digest, not latest or tag-only" >&2
  failures=$((failures + 1))
else
  echo "PASS test9: seeded negative — no unpinned/latest base images"
fi

# ---------------------------------------------------------------------------
# Test 10 (seeded negative): No Alpine packages
# ---------------------------------------------------------------------------
if grep -q 'apk add' "${dockerfile}" "${build_script}"; then
  echo "FAIL test10: FRR tooling image must not use the Alpine PPP package path" >&2
  failures=$((failures + 1))
else
  echo "PASS test10: seeded negative — no Alpine apk packages"
fi

# ---------------------------------------------------------------------------
# Test 11: update-repo-cache-with-vm.sh contract checks
# ---------------------------------------------------------------------------
cache_update="${repo_root}/docker-clab-frr-plus-tooling/update-repo-cache-with-vm.sh"
if [[ -f "${cache_update}" ]]; then
  checks_ok=1
  grep -q './start-vm.sh "${example}"' "${cache_update}" || checks_ok=0
  grep -q 'CLAB_FRR_TOOLING_REPO_CACHE_DIR' "${cache_update}" || checks_ok=0
  grep -q 'renderer repository is under /nix/store' "${cache_update}" || checks_ok=0
  grep -q 'user-supplied cache/export directory' "${cache_update}" || checks_ok=0
  grep -q 'must not point into /nix/store' "${cache_update}" || checks_ok=0
  grep -q 'CLAB_FRR_TOOLING_CACHE_DIR="${cache_dir}"' "${cache_update}" || checks_ok=0
  grep -q 'test -s "${cache_tar}"' "${cache_update}" || checks_ok=0
  grep -q 'test -s "${cache_id}"' "${cache_update}" || checks_ok=0
  grep -q 'docker run --rm --entrypoint /bin/sh clab-frr-plus-tooling:latest' "${cache_update}" || checks_ok=0
  grep -q 'test -x /usr/lib/frr/staticd' "${cache_update}" || checks_ok=0
  grep -q 'shutdown -h now' "${cache_update}" || checks_ok=0
  if (( checks_ok == 1 )); then
    echo "PASS test11: update-repo-cache-with-vm.sh contract checks"
  else
    echo "FAIL test11: update-repo-cache-with-vm.sh contract incomplete" >&2
    failures=$((failures + 1))
  fi
else
  echo "SKIP test11: update-repo-cache-with-vm.sh not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-020: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-020: Docker/VM readiness acceptance predicates covered"
