#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/run-in-vm.sh"

grep -q 'docker_wait_seconds=' "${script}"
grep -q 'wait_for_docker()' "${script}"
grep -q 'systemctl start docker' "${script}"
grep -q 'docker info' "${script}"
grep -q 'docker did not become ready' "${script}"
