# ./run-clab-generator.sh
#!/usr/bin/env bash
set -euo pipefail

#nix flake update --flake path:.

#nix run .#generate-clab-config ../network-compiler/examples/single-wan/inputs.nix
#nix run .#generate-clab-config ../network-compiler/examples/single-wan-any-to-any-fw/inputs.nix
nix run .#generate-clab-config ../network-compiler/examples/single-wan-with-nebula/inputs.nix
#nix run .#generate-clab-config ../network-compiler/examples/overlay-east-west/inputs.nix
#nix run .#generate-clab-config ../network-compiler/examples/multi-wan/inputs.nix fabric.clab.yml vm-bridges-generated.nix


echo links generated:
sed -n '/links:/,$p' fabric.clab.yml
echo bridges linux:
cat ./vm-bridges-generated.nix
