#!/usr/bin/env bash
set -euo pipefail

INPUT_NIX="../network-compiler/examples/single-wan/inputs.nix"
INPUT_NIX="../network-compiler/examples/single-wan/inputs.nix"
#INPUT_NIX="../network-compiler/examples/single-wan-with-nebula/inputs.nix"
TOPO_OUT="fabric.clab.yml"
BRIDGES_OUT="vm-bridges-generated.nix"

rm -f "$TOPO_OUT" "$BRIDGES_OUT"

CLABGEN_ROUTING_MODE=bgp nix run .#generate-clab-config "$INPUT_NIX" "$TOPO_OUT" "$BRIDGES_OUT"

echo links generated:
sed -n '/links:/,$p' "$TOPO_OUT"
echo bridges linux:
cat "./$BRIDGES_OUT"
