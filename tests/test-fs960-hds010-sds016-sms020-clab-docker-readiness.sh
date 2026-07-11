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
#  9. VM example harness fail-closes runtime validation failures
# 10. CLAB WAN runtime commands use valid nftables/NAT syntax
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
   grep -q 'deploy_containerlab()' "${script}" &&
   grep -q 'run_containerlab_deploy_once()' "${script}" &&
   grep -q 'CLAB_DEPLOY_TIMEOUT_SECONDS' "${script}" &&
   grep -q 'CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS' "${script}" &&
   grep -q 'CLAB_CONTAINERLAB_API_TIMEOUT' "${script}" &&
   grep -q 'CLAB_DEPLOY_MAX_WORKERS' "${script}" &&
   grep -q -- '--timeout "${containerlab_api_timeout}"' "${script}" &&
   grep -q -- '--max-workers "${deploy_max_workers}"' "${script}" &&
   grep -q 'stop_containerlab_deploy()' "${script}" &&
   grep -q 'Containerlab deploy emitted ERRO; stopping attempt' "${script}" &&
   grep -q 'Containerlab deploy produced no output' "${script}" &&
   grep -q 'CLAB_SYSTEMCTL_TIMEOUT_SECONDS' "${script}" &&
   grep -q 'CLAB_DOCKER_INFO_TIMEOUT_SECONDS' "${script}" &&
   grep -q 'failed to Statfs "/proc/0/ns/net"' "${script}" &&
   grep -q 'failed deploy links.*file exists' "${script}" &&
   grep -q 'systemctl start docker' "${script}" &&
   grep -q 'docker_cmd.* info' "${script}" &&
   grep -q 'docker did not become ready' "${script}" &&
   grep -q 'CLAB_DEPLOY_ATTEMPTS' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'CLAB_CONTAINERLAB_API_TIMEOUT' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'CLAB_DEPLOY_MAX_WORKERS' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'CLAB_VM_VALIDATION_TIMEOUT_SECONDS' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'if ! ssh_vm_once "' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'if ! guard_vm_runtime_log "${validation_log}"; then' "${repo_root}/tests/lib/vm-lifecycle.sh" &&
   grep -q 'if ! run_in_vm_validation "${validation_log}"; then' "${repo_root}/tests/test-vm-examples.sh"; then
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
  grep -q 'compile_example_cpm "${example}" "${cpm_json}"' "${cache_update}" || checks_ok=0
  grep -q './start-vm.sh "${cpm_json}"' "${cache_update}" || checks_ok=0
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
# Test 12: VM example runtime failures must fail-close
# ---------------------------------------------------------------------------
if grep -q 'if ! run_in_vm_validation "${validation_log}"; then' "${repo_root}/tests/test-vm-examples.sh" &&
   grep -q 'if ! ssh_vm_once "' "${repo_root}/tests/lib/vm-runtime-targets.sh" &&
   grep -q 'extract_runtime_target_tenant_dataplane_checks' "${repo_root}/tests/test-vm-examples.sh" &&
   grep -q 'check_runtime_target_tenant_dataplane' "${repo_root}/tests/test-vm-examples.sh" &&
   grep -q 'ip route get 8.8.8.8 from ${source4} iif ${tenant_if}' "${repo_root}/tests/lib/vm-runtime-targets.sh" &&
   grep -q 'return 1' "${repo_root}/tests/test-vm-examples.sh" &&
   grep -q 'FATAL VM-backed Containerlab validation emitted runtime errors' "${repo_root}/tests/lib/vm-runtime-log-guard.sh" &&
   grep -q 'test-vm-examples.sh)' "${repo_root}/run-all-tests.sh" &&
   grep -q 'NETWORK_REPO_RUNTIME_TEST_OK' "${repo_root}/run-all-tests.sh" &&
   grep -q 'VM-backed example matrix; explicit runtime opt-in' "${repo_root}/run-all-tests.sh"; then
  echo "PASS test12: VM example runtime validation fail-closes"
else
  echo "FAIL test12: VM example runtime validation can be masked" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 13: CLAB WAN command rendering avoids invalid runtime syntax
# ---------------------------------------------------------------------------
if ! grep -q 'str(ipv4.get("clientAddress"))' "${repo_root}/clabgen/s88/CM/linux_wan_dynamic.py" &&
   grep -q 'meta l4proto icmpv6 accept' "${repo_root}/clabgen/s88/CM/firewall_wan.py" &&
   ! grep -q 'ipv6-icmp' "${repo_root}/clabgen/s88/CM/firewall_wan.py" &&
   ! grep -q 'ipv6-icmp' "${repo_root}/fabric.clab.example.yml" &&
   ! grep -q 'ipv6-icmp' "${repo_root}/run-in-vm.example-output.txt"; then
  echo "PASS test13: CLAB WAN command rendering uses valid NAT and nftables syntax"
else
  echo "FAIL test13: CLAB WAN command rendering still allows invalid runtime syntax" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Test 14: run-in-vm diagnostics avoid false main-table internet probes
# ---------------------------------------------------------------------------
if grep -q 'skipped: no main-table default route' "${repo_root}/run-in-vm.sh" &&
   grep -q 'if docker exec "$c" sh -c '\''ip route show default | grep -q "^default "'\''; then' "${repo_root}/run-in-vm.sh" &&
   grep -q 'docker exec "$c" ip route get 8.8.8.8 || true' "${repo_root}/run-in-vm.sh" &&
   grep -q 'docker exec "$c" traceroute -I -n -w 1 -q 1 -m 8 8.8.8.8 || true' "${repo_root}/run-in-vm.sh"; then
  echo "PASS test14: run-in-vm diagnostics skip nodes without main default routes"
else
  echo "FAIL test14: run-in-vm still emits false main-table internet probes" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  echo "FAIL FS-960-HDS-010-SDS-016-SMS-020: ${failures} test(s) failed" >&2
  exit 1
fi

echo "PASS FS-960-HDS-010-SDS-016-SMS-020: Docker/VM readiness acceptance predicates covered"
