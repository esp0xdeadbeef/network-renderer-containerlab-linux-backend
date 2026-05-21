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
grep -q 'frrouting/frr@sha256:' "${dockerfile}"
grep -q 'frrouting/frr@sha256:' "${build_script}"
grep -q 'command -v rg' "${dockerfile}"
grep -q 'command -v nmap' "${dockerfile}"
grep -q 'ripgrep' "${dockerfile}"
grep -q 'nmap' "${dockerfile}"
if grep -q 'frrouting/frr:latest' "${dockerfile}" "${build_script}"; then
  echo "FRR tooling base image must be pinned by digest, not latest" >&2
  exit 1
fi
