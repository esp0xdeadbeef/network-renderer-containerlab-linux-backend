#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_in_vm="${repo_root}/run-in-vm.sh"

grep -q 'containerlab destroy --all --cleanup --yes' "${run_in_vm}" || {
  echo "run-in-vm.sh must clear stale Containerlab labs before each VM example deploy" >&2
  exit 1
}

grep -q "grep '^clab-fabric-'" "${run_in_vm}" || {
  echo "run-in-vm.sh must remove stale clab-fabric containers before each VM example deploy" >&2
  exit 1
}

echo "PASS vm-example-lab-cleanup"
