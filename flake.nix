{
  description = "network-renderer-containerlab-linux-backend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    { self
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
    };
}
