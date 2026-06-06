#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/run-in-vm.sh"
dockerfile="${repo_root}/docker-clab-frr-plus-tooling/Dockerfile"
build_script="${repo_root}/docker-clab-frr-plus-tooling/build.sh"

grep -q 'docker_wait_seconds=' "${script}"
grep -q 'wait_for_docker()' "${script}"
grep -q 'systemctl start docker' "${script}"
grep -q 'docker info' "${script}"
grep -q 'docker did not become ready' "${script}"
grep -q 'debian:bookworm-slim@sha256:' "${dockerfile}"
grep -q 'debian:bookworm-slim@sha256:' "${build_script}"
grep -q 'verify_tooling_image()' "${build_script}"
grep -q 'docker run --rm --entrypoint /bin/sh "$IMAGE"' "${build_script}"
grep -q 'verify_tooling_image' "${build_script}"
grep -q 'docker load -i "${CACHE_TAR}"' "${build_script}"
grep -q -- '--pull=false' "${build_script}"
grep -q -- '--label "${LABEL_KEY}=${CACHE_KEY}"' "${build_script}"
grep -q 'docker save "$IMAGE" -o "${CACHE_TAR}"' "${build_script}"
grep -q 'CLAB_FRR_TOOLING_CACHE_EVIDENCE_JSON' "${build_script}"
grep -q '"schema": "clab-frr-tooling-cache-evidence.v1",' "${build_script}"
grep -q '"cachePresentAtStart": bool_env("CACHE_PRESENT_AT_START")' "${build_script}"
grep -q '"cacheLoaded": bool_env("CACHE_LOADED")' "${build_script}"
grep -q '"imageBuilt": bool_env("CACHE_BUILT")' "${build_script}"
grep -q 'apt-get install -y --no-install-recommends' "${dockerfile}"
grep -q 'rm -rf /var/lib/apt/lists/' "${dockerfile}"
grep -q 'ripgrep' "${dockerfile}"
grep -q 'nmap' "${dockerfile}"
grep -q 'test -x /usr/lib/frr/staticd' "${dockerfile}"
grep -q 'test -x /usr/lib/frr/staticd' "${build_script}"
grep -q 'test -x /usr/lib/frr/bgpd' "${dockerfile}"
grep -q 'test -x /usr/lib/frr/bgpd' "${build_script}"
grep -q 'test -x /usr/lib/frr/zebra' "${dockerfile}"
grep -q 'test -x /usr/lib/frr/zebra' "${build_script}"
for command_name in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff udhcpc udhcpd vtysh python3; do
  grep -q 'command -v "$cmd"' "${build_script}" || {
    echo "FRR tooling builder must verify package commands before cache export" >&2
    exit 1
  }
  grep -q "${command_name}" "${dockerfile}" "${build_script}" || {
    echo "FRR tooling package command ${command_name} must be present in Dockerfile or builder verification" >&2
    exit 1
  }
done
build_line="$(grep -n 'docker build' "${build_script}" | head -n1 | cut -d: -f1)"
save_line="$(grep -n 'docker save "$IMAGE" -o "${CACHE_TAR}"' "${build_script}" | head -n1 | cut -d: -f1)"
verify_line="$(
  awk -v build="${build_line}" -v save="${save_line}" '
    NR > build && NR < save && /verify_tooling_image/ { print NR; exit }
  ' "${build_script}"
)"
if [[ -z "${build_line}" || -z "${verify_line}" || -z "${save_line}" || "${build_line}" -ge "${verify_line}" || "${verify_line}" -ge "${save_line}" ]]; then
  echo "FRR tooling builder must verify package commands after build and before cache save" >&2
  exit 1
fi
if grep -qE 'frrouting/frr:latest|debian:latest|bookworm-slim($|")' "${dockerfile}" "${build_script}"; then
  echo "FRR tooling base image must be pinned by digest, not latest or tag-only" >&2
  exit 1
fi
if grep -q 'apk add' "${dockerfile}" "${build_script}"; then
  echo "FRR tooling image must not use the Alpine PPP package path" >&2
  exit 1
fi

cache_update="${repo_root}/docker-clab-frr-plus-tooling/update-repo-cache-with-vm.sh"
grep -q './start-vm.sh "${example}"' "${cache_update}"
grep -q 'CLAB_FRR_TOOLING_REPO_CACHE_DIR' "${cache_update}"
grep -q 'renderer repository is under /nix/store' "${cache_update}"
grep -q 'user-supplied cache/export directory' "${cache_update}"
grep -q 'must not point into /nix/store' "${cache_update}"
grep -q 'CLAB_FRR_TOOLING_CACHE_DIR="${cache_dir}"' "${cache_update}"
grep -q 'test -s "${cache_tar}"' "${cache_update}"
grep -q 'test -s "${cache_id}"' "${cache_update}"
grep -q 'docker run --rm --entrypoint /bin/sh clab-frr-plus-tooling:latest' "${cache_update}"
grep -q 'test -x /usr/lib/frr/staticd' "${cache_update}"
grep -q 'shutdown -h now' "${cache_update}"
