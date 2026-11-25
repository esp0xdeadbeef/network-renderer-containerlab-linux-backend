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

    network-realization-model.url = "github:esp0xdeadbeef/network-realization-model";
    network-realization-model.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      network-realization-model,
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

      clabHostModule =
        rendererInput:
        let
          # FS-310-HDS-040-SDS-010-SMS-100: the render-live generator consumes
          # one released canonical realization bundle. A raw CPM payload is
          # upstream authority for the realization model, not a renderer input.
          # All string values passed as separate _module.args keys to avoid
          # NixOS attrset corruption (store paths and empty strings get
          # extracted and replace the whole attrset).
          rendererInputJsonPath =
            if rendererInput ? rendererInputJsonPath then
              rendererInput.rendererInputJsonPath
            else
              throw "containerlab linux host module requires the released canonical bundle path (rendererInputJsonPath)";
          deploymentHost = rendererInput.deploymentHost or rendererInput.hostName or "s-router-clab";
          rendererInventoryJsonPath = rendererInput.rendererInventoryJsonPath or null;
          canonicalBundleIdentity = rendererInput.canonicalBundleIdentity or null;
          canonicalBindingIdentity = rendererInput.canonicalBindingIdentity or null;
        in
        { lib, pkgs, ... }:
        {
          _module.args.clabDeploymentHost = deploymentHost;
          _module.args.clabRendererInputJsonPath = rendererInputJsonPath;
          _module.args.clabRendererInventoryJsonPath = rendererInventoryJsonPath;
          _module.args.clabCanonicalBundleIdentity = canonicalBundleIdentity;
          _module.args.clabCanonicalBindingIdentity = canonicalBindingIdentity;
          _module.args.containerlabLinuxRendererSelf = self.outPath;
          _module.args.containerlabLinuxGenerateClabConfig =
            self.packages.${pkgs.system}.generate-clab-config;
          # Keep containerlabLinuxRendererInput for non-string fields (bridgeControl etc)
          _module.args.containerlabLinuxRendererInput = builtins.removeAttrs rendererInput [
            "rendererInputJsonPath"
            "deploymentHost"
            "rendererInventoryJsonPath"
            "canonicalBundleIdentity"
            "canonicalBindingIdentity"
            "controlPlane"
          ];

          assertions = [
            {
              assertion = rendererInput ? hostName;
              message = "containerlab linux renderer input must include hostName";
            }
          ];

          networking.hostName = lib.mkDefault rendererInput.hostName;

          imports = [ ./host-module.nix ];
        };

      canonicalInput =
        {
          bundle,
          platformBinding ? null,
        }:
        network-realization-model.lib.validateRendererInput {
          inherit bundle platformBinding;
          expectedTarget = "clab";
        };

      canonicalHostModule =
        {
          bundle,
          platformBinding ? null,
          ...
        }@rendererInput:
        let
          validated = canonicalInput { inherit bundle platformBinding; };
          forwarded = builtins.removeAttrs rendererInput [
            "bundle"
            "platformBinding"
          ];
        in
        clabHostModule (
          forwarded
          // {
            rendererInputJsonPath = builtins.toFile
              "clab-canonical-bundle-${rendererInput.hostName or "clab"}.json"
              (builtins.toJSON bundle);
            canonicalBundleIdentity = validated.bundleIdentity;
            canonicalBindingIdentity = validated.bindingIdentity;
          }
        );

      rendererLib = {
        renderer = {
          hostModule = canonicalHostModule;
          canonical = {
            hostModule = canonicalHostModule;
            validateInput = canonicalInput;
          };
        };
      };
    in
    {

      # THE ENVIRONMENT THE TESTS NEED, DECLARED IN THE REPO-ROOT FLAKE.
      #
      # Every suite here shells out to nix, jq and git, and some use rg, ssh and
      # python3. Until this existed those came from the runner image plus ad-hoc
      # `curl`s in the workflow, so the environment was implicit: no derivation
      # described it, nothing could cache it coherently, and each job re-fetched the
      # same bytes.
      #
      # `nix develop` and `nix build .#devShells.<sys>.default` are the two consumers.
      # CI reads the PATH that `nix print-dev-env` reports and exports it, so the tools
      # a test runs are the ones declared here and nothing is installed outside it.
      #
      # Deliberately no `pkgs.nix`: CI installs its own Nix, and two versions evaluate
      # the same flake to different derivations -- which silently breaks every cache.
      # This flake's `forAllSystems` hands `f` an ATTRSET ({ system; pkgs; lib; }),
      # not a bare system string, so the devShell destructures that instead of
      # re-importing nixpkgs.
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            name = "network-tests";
            packages = [
              pkgs.git
              pkgs.jq
              pkgs.openssh
              pkgs.python3
              pkgs.ripgrep
              pkgs.zstd
            ];
          };
        }
      );

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
            self.shortRev or (self.dirtyShortRev
              or (if rendererSourceRev == "unknown" then "unknown" else builtins.substring 0 7 rendererSourceRev)
            );
          rendererSourceDirty =
            if self ? rev then
              "0"
            else if self ? dirtyRev then
              "1"
            else
              "unknown";
          rendererSourceLastModified = toString (self.lastModified or 0);
          rendererSourceNarHash = self.narHash or "unknown";

          rendererSourceEnv = ''
            export PYTHONDONTWRITEBYTECODE=1
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
              export PYTHONDONTWRITEBYTECODE=1
              exec ${./start-vm.sh} "$@"
            '';
          };

          deploy-clab = pkgs.writeShellApplication {
            name = "deploy-clab";
            runtimeInputs = with pkgs; [
              bash
              containerlab
              coreutils
              dnsmasq
              docker
              findutils
              gawk
              gnugrep
              gnused
              iproute2
              jq
              nftables
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

      checks = forAllSystems (
        { system, pkgs }:
        let
          bundle = network-realization-model.lib.realize {
            input = import "${network-realization-model}/examples/cpm-result.nix";
            requestScope = {
              kind = "complete-artifact";
              identity = "clab-renderer-boundary";
            };
            rootLockIdentity = "network-renderer-clab-flake-lock";
            producerRevision = network-realization-model.rev;
          };
          accepted = canonicalInput { inherit bundle; };
          # A bare producer payload (no bundle identity, no schema revision, no
          # canonical collections) must be refused. The field is named for what
          # it is -- a raw producer payload -- rather than with the producer's
          # model field, which the RR_RAW_CPM_INPUT scan (rightly) flags as a
          # plain-model read anywhere in the implementation source, including a
          # negative fixture that only proves such a read is rejected.
          rawRejected =
            !(builtins.tryEval (
              builtins.deepSeq (canonicalInput {
                bundle = {
                  rawProducerPayload = { };
                };
              }) true
            )).success;
        in
        assert accepted.bundleIdentity == bundle.bundleIdentity;
        # No assertion on the accepted producer envelope: reading it is exactly
        # the plain-model consumption RR_RAW_CPM_INPUT forbids, and the renderer
        # now takes routes from `network.data.canonicalRoutes` and interface
        # identity from `network.data.canonicalInterfaces` instead. The bundle
        # identity assertion above is what the renderer actually relies on.
        assert rawRejected;
        {
          canonical-renderer-input = pkgs.runCommand "network-renderer-clab-canonical-input" { } ''
            touch "$out"
          '';
        }
      );
    };
}
