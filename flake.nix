{
  description = "network-renderer-containerlab-linux-backend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
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
        in
        {
          generate-clab-config = pkgs.writeShellApplication {
            name = "generate-clab-config";
            runtimeInputs = [
              pythonEnv
            ];
            text = ''
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

          default = self.apps.${system}.generate-clab-config;
        }
      );
    };
}
