# ./start-vm.sh
#!/usr/bin/env bash
set -euo pipefail

./run-clab-generator.sh
touch ./nixos.qcow2
rm -f ./nixos.qcow2

export QEMU_NET_OPTS="hostfwd=tcp::2222-:22"
echo "ssh -o 'StrictHostKeyChecking no' -p2222 root@localhost # to connect to the vm."

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -euo pipefail

export QEMU_NET_OPTS="hostfwd=tcp::2222-:22"
echo "ssh -o 'StrictHostKeyChecking no' -p2222 root@localhost # to connect to the vm."

#!/usr/bin/env bash
set -euo pipefail

export QEMU_NET_OPTS="hostfwd=tcp::2222-:22"
echo "ssh -o 'StrictHostKeyChecking no' -p2222 root@localhost # to connect to the vm."

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOLVER_INPUT="${FLAKE_DIR}/../network-compiler/examples/multi-wan/inputs.nix"
SOLVER_JSON="${FLAKE_DIR}/output-network-solver.json"
TOPO_FILE="${FLAKE_DIR}/fabric.clab.yml"
BRIDGES_FILE="${FLAKE_DIR}/vm-bridges-generated.nix"

if [ ! -f "${SOLVER_JSON}" ] || [ ! -f "${BRIDGES_FILE}" ]; then
  echo "[*] Generating solver JSON, topology and bridges..."
  #nix run .#generate-clab-config "${SOLVER_INPUT}" "${TOPO_FILE}" "${BRIDGES_FILE}"
  ./run-clab-generator.sh
fi

echo "[*] Starting VM via nixos-shell (preserving custom options)..."
nix run --extra-experimental-features 'nix-command flakes' nixpkgs#nixos-shell -- "${FLAKE_DIR}/vm.nix"
