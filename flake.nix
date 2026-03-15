# ./flake.nix
{
  description = "Containerlab VM host + network renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/0182a361324364ae3f436a63005877674cf45efb";

    network-control-plane-model.url =
      "github:esp0xdeadbeef/network-control-plane-model";

    network-compiler.url =
      "github:esp0xdeadbeef/network-compiler";

    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";
    network-compiler.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, network-control-plane-model, network-compiler }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      pythonEnv = pkgs.python3.withPackages (ps: [
        ps.pyyaml
        ps.pandas
      ]);

      controlPlaneApp =
        network-control-plane-model.apps.${system}.control-plane-model.program;

      rendererScript = pkgs.writeText "generate-clab-config.py"
        (builtins.readFile ./generate-clab-config.py);
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
                echo "Usage: $0 <input.nix> [output-topology.yml] [output-bridges.nix]" >&2
                exit 1
              fi

              INPUT_NIX="$1"
              CONTROL_JSON="control-plane-model.json"
              TOPO_OUT="''${2:-fabric.clab.yml}"
              BRIDGES_OUT="''${3:-vm-bridges-generated.nix}"

              echo "[*] Running control-plane-model..."
              ${controlPlaneApp} "$INPUT_NIX" "$CONTROL_JSON"

              echo "[*] Validating JSON..."
              jq empty "$CONTROL_JSON"

              echo "[*] Generating Containerlab topology..."

              export PYTHONPYCACHEPREFIX=/tmp/python-cache

              PYTHONPATH="$(pwd)" \
              ${pythonEnv}/bin/python3 ${rendererScript} \
                "$CONTROL_JSON" \
                "$TOPO_OUT" \
                "$BRIDGES_OUT"
            '';
          };

        default = self.packages.${system}.generate-clab-config;
      };

      apps.${system} = {
        generate-clab-config = {
          type = "app";
          program =
            "${self.packages.${system}.generate-clab-config}/bin/generate-clab-config";
        };

        default = self.apps.${system}.generate-clab-config;
      };

      defaultPackage.${system} =
        self.packages.${system}.generate-clab-config;
    };
}
