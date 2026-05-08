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

grep -q 'wait_for_required_bridges' "${run_in_vm}" || {
  echo "run-in-vm.sh must wait for generated VM bridges before Containerlab deploy" >&2
  exit 1
}

grep -q 'missing required host bridges after' "${run_in_vm}" || {
  echo "run-in-vm.sh must fail with explicit missing bridge names" >&2
  exit 1
}

echo "PASS vm-example-lab-cleanup"
