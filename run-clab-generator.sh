#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ./run-clab-generator.sh <control-plane-model.json|output-solver.json> [topology_out] [bridges_out]

defaults:
  - If no input is provided, tries (in order):
      ./output-control-plane-model-signed.json
      ./output-control-plane-model.json
      ./control-plane-model.json
      ./output-solver-signed.json
      ./output-solver.json

EOF
}

INPUT="${1:-}"
TOPO_OUT="${2:-fabric.clab.yml}"
BRIDGES_OUT="${3:-vm-bridges-generated.nix}"

if [[ -z "$INPUT" ]]; then
  for candidate in \
    "./output-control-plane-model-signed.json" \
    "./output-control-plane-model.json" \
    "./control-plane-model.json" \
    "./output-solver-signed.json" \
    "./output-solver.json"
  do
    if [[ -f "$candidate" ]]; then
      INPUT="$candidate"
      break
    fi
  done
fi

if [[ -z "$INPUT" ]]; then
  usage
  exit 1
fi

rm -f "$TOPO_OUT" "$BRIDGES_OUT"
nix run .#generate-clab-config -- "$INPUT" "$TOPO_OUT" "$BRIDGES_OUT"

echo "links generated:"
sed -n '/links:/,$p' "$TOPO_OUT" || true
echo "bridges (nix):"
cat "./$BRIDGES_OUT"
