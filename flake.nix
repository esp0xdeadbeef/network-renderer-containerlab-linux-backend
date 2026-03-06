{
  description = "Containerlab VM host + network renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    network-solver.url = "github:esp0xdeadbeef/network-solver";
    network-compiler.url = "github:esp0xdeadbeef/network-compiler";

    network-solver.inputs.nixpkgs.follows = "nixpkgs";
    network-compiler.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, network-solver, network-compiler }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    pythonEnv = pkgs.python3.withPackages (ps: [
      ps.pyyaml
      ps.pandas
    ]);

    solverApp =
      network-solver.apps.${system}.compile-and-solve.program;
  in
  {
    nixosConfigurations.lab = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ ./vm.nix ];
    };

    packages.${system} = {
      generate-clab-config =
        pkgs.writeShellApplication {
          name = "generate-clab-config";

          runtimeInputs = [
            pythonEnv
            pkgs.jq
          ];

          text = ''
            set -euo pipefail

            if [ "$#" -lt 1 ]; then
              echo "Usage: $0 <input.nix> [output-topology.yml] [output-bridges.nix]"
              exit 1
            fi

            INPUT_NIX="$1"
            OUTPUT_JSON="output-solver-signed.json"
            TOPO_OUT="''${2:-fabric.clab.yml}"
            BRIDGES_OUT="''${3:-vm-bridges-generated.nix}"

            echo "[*] Running solver..."
            ${solverApp} "$INPUT_NIX" > "$OUTPUT_JSON"

            echo "[*] Validating JSON..."
            jq empty "$OUTPUT_JSON"

            echo "[*] Generating Containerlab topology..."

            export PYTHONPYCACHEPREFIX=/tmp/python-cache

            PYTHONPATH="$(pwd)" \
              ${pythonEnv}/bin/python3 ${./generate-clab-config.py} \
                "$OUTPUT_JSON" "$TOPO_OUT" "$BRIDGES_OUT"
          '';
        };
    };

    apps.${system} = {
      generate-clab-config = {
        type = "app";
        program =
          "${self.packages.${system}.generate-clab-config}/bin/generate-clab-config";
      };

      default = {
        type = "app";
        program =
          "${self.packages.${system}.generate-clab-config}/bin/generate-clab-config";
      };
    };

    defaultPackage.${system} =
      self.packages.${system}.generate-clab-config;
  };
}
