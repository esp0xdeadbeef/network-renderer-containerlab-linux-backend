{
  description = "network-renderer-containerlab-linux-backend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";

    network-compiler.url = "github:esp0xdeadbeef/network-compiler";
    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model";

    network-compiler.inputs.nixpkgs.follows = "nixpkgs";
    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs @ { self
    , nixpkgs
    , ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );

      rendererLib = {
        renderer.hostModule =
          rendererInput:
          let
            # Accept cpm (Nix CPM structure) and convert to JSON path.
            # Format conversion only — no lab-specific file paths.
            resolvedInput =
              if rendererInput ? cpmJsonPath then rendererInput
              else if rendererInput ? cpm then
                rendererInput // {
                  cpmJsonPath = builtins.toFile
                    "cpm-${rendererInput.hostName or "clab"}.json"
                    (builtins.toJSON rendererInput.cpm);
                  rendererInventoryJsonPath = rendererInput.rendererInventoryJsonPath or "";
                  deploymentHost = rendererInput.deploymentHost or rendererInput.hostName or "s-router-clab";
                }
              else rendererInput;
          in
          { lib, ... }:
          {
            _module.args.containerlabLinuxRendererInput = resolvedInput;
            _module.args.containerlabLinuxRendererSelf = self.outPath;

            assertions = [
              {
                assertion = resolvedInput ? hostName;
                message = "containerlab linux renderer input must include hostName";
              }
            ];

            networking.hostName = lib.mkDefault resolvedInput.hostName;

            imports = [ ./host-module.nix ];
          };
      };
    in
    {
      packages = forAllSystems (
        { system, pkgs }:
        let
          pythonEnv = pkgs.python3.withPackages (
            ps: with ps; [
              pyyaml
            ]
          );

          repoRoot = ./.;
          rendererSourceName = "network-renderer-containerlab-linux-backend";
          rendererSourceRev = self.rev or (self.dirtyRev or "unknown");
          rendererSourceShortRev =
            self.shortRev or (self.dirtyShortRev or (
              if rendererSourceRev == "unknown" then "unknown" else builtins.substring 0 7 rendererSourceRev
            ));
          rendererSourceDirty =
            if self ? rev then "0" else if self ? dirtyRev then "1" else "unknown";
          rendererSourceLastModified = toString (self.lastModified or 0);
          rendererSourceNarHash = self.narHash or "";

          rendererSourceEnv = ''
            export CLAB_RENDERER_SOURCE_NAME="${rendererSourceName}"
            export CLAB_RENDERER_SOURCE_REV="${rendererSourceRev}"
            export CLAB_RENDERER_SOURCE_SHORT_REV="${rendererSourceShortRev}"
            export CLAB_RENDERER_SOURCE_DIRTY="${rendererSourceDirty}"
            export CLAB_RENDERER_SOURCE_LAST_MODIFIED="${rendererSourceLastModified}"
            export CLAB_RENDERER_SOURCE_NAR_HASH="${rendererSourceNarHash}"
            export CLAB_RENDERER_SOURCE_OUT_PATH="${repoRoot}"
          '';
        in
        {
          generate-clab-config = pkgs.writeShellApplication {
            name = "generate-clab-config";
            runtimeInputs = [
              pythonEnv
            ];
            text = ''
              ${rendererSourceEnv}
              export PYTHONPATH="${repoRoot}:''${PYTHONPATH:+:$PYTHONPATH}"
              exec ${pythonEnv}/bin/python ${./generate-clab-config.py} "$@"
            '';
          };

          start-vm = pkgs.writeShellApplication {
            name = "start-vm";
            runtimeInputs = with pkgs; [
              bash
              qemu
            ];
            text = ''
              exec ${./start-vm.sh} "$@"
            '';
          };

          deploy-clab = pkgs.writeShellApplication {
            name = "deploy-clab";
            runtimeInputs = with pkgs; [
              bash
              containerlab
              coreutils
              docker
              findutils
              gawk
              gnugrep
              gnused
              iproute2
              jq
              pythonEnv
            ];
            text = ''
              ${rendererSourceEnv}
              export CLAB_RENDERER_ROOT="${repoRoot}"
              export CLABGEN_PYTHON="${pythonEnv}/bin/python"
              export PYTHONPATH="${repoRoot}:''${PYTHONPATH:+:$PYTHONPATH}"
              exec ${./deploy-clab.sh} "$@"
            '';
          };

          default = self.packages.${system}.generate-clab-config;
        }
      );

      apps = forAllSystems (
        { system, ... }:
        {
          generate-clab-config = {
            type = "app";
            program = "${self.packages.${system}.generate-clab-config}/bin/generate-clab-config";
          };

          start-vm = {
            type = "app";
            program = "${self.packages.${system}.start-vm}/bin/start-vm";
          };

          deploy-clab = {
            type = "app";
            program = "${self.packages.${system}.deploy-clab}/bin/deploy-clab";
          };

          default = self.apps.${system}.generate-clab-config;
        }
      );

      lib = rendererLib;

      libBySystem = forAllSystems (
        { ... }:
        rendererLib
      );
    };
}
