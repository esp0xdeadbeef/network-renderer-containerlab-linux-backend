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

lifecycle="${repo_root}/tests/lib/vm-lifecycle.sh"
checks="${repo_root}/tests/lib/vm-example-checks.sh"

grep -q 'vm_remote_topology_file=' "${lifecycle}" || {
  echo "VM example validation must use a per-VM remote topology path" >&2
  exit 1
}

grep -q "CLAB_TOPO_FILE='\${vm_remote_topology_file}'" "${lifecycle}" || {
  echo "run-in-vm.sh must validate the per-VM staged topology, not shared repo-root fabric.clab.yml" >&2
  exit 1
}

if grep -q 'CLAB_TOPO_FILE=.*repo_root.*/fabric.clab.yml' "${lifecycle}"; then
  echo "VM matrix workers must not share repo-root fabric.clab.yml as the active topology" >&2
  exit 1
fi

grep -q 'vm_remote_topology_file' "${checks}" || {
  echo "VM example post-checks must inspect the per-VM staged topology" >&2
  exit 1
}

echo "PASS vm-example-lab-cleanup"
