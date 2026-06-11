{ config
, lib
, pkgs
, containerlabLinuxRendererInput
, containerlabLinuxRendererSelf  ? null
, containerlabLinuxRendererInputs ? { }
, sRouterClabLabProfile ? { }
, ...
}:
let
  inherit (lib) mkDefault mkForce optionalString;

  labSource = sRouterClabLabProfile.labSource or containerlabLinuxRendererInput.labSource or "sat";
  deploymentHost = sRouterClabLabProfile.deploymentHost or containerlabLinuxRendererInput.deploymentHost or "s-router-clab";

  rendererRepo = if containerlabLinuxRendererSelf == null then null else containerlabLinuxRendererSelf;
  labsRepo = if containerlabLinuxRendererInputs ? "network-labs" then containerlabLinuxRendererInputs.network-labs else null;
  compilerRepo = if containerlabLinuxRendererInputs ? "network-compiler" then containerlabLinuxRendererInputs.network-compiler else null;
  forwardingRepo = if containerlabLinuxRendererInputs ? "network-forwarding-model" then containerlabLinuxRendererInputs.network-forwarding-model else null;
  cpmRepo = if containerlabLinuxRendererInputs ? "network-control-plane-model" then containerlabLinuxRendererInputs.network-control-plane-model else null;

  hasAllRepos = rendererRepo != null && labsRepo != null && compilerRepo != null
             && forwardingRepo != null && cpmRepo != null;

  s-router-clab-render-live =
    if hasAllRepos then
    pkgs.writeShellApplication {
      name = "s-router-clab-render-live";
      runtimeInputs = [
        pkgs.bash
        pkgs.containerlab
        pkgs.coreutils
        pkgs.docker
        pkgs.findutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnumake
        pkgs.iproute2
        pkgs.jq
        pkgs.nix
        pkgs.python3
        pkgs.systemd
        pkgs.util-linux
      ];
      text = ''
        set -euo pipefail

        export NIX_CONFIG="experimental-features = nix-command flakes"

        renderer_repo="${rendererRepo}"
        labs_repo="${labsRepo}"
        compiler_repo="${compilerRepo}"
        forwarding_repo="${forwardingRepo}"
        cpm_repo="${cpmRepo}"
        work_dir="''${1:-/persist/s-router-clab/live-$(date +%s)}"
        lab_source="${labSource}"
        lab_dir="$labs_repo/$lab_source"
        artifact_dir="$work_dir/network-artifacts"
        status_marker="$work_dir/s-router-clab-render-live-status.json"
        service_name="s-router-clab-render-live"
        phase="render-start"

        write_status() {
          local result="$1"
          local status_phase="$2"
          local failure_reason="''${3:-}"
          mkdir -p "$work_dir"
          jq -S -n \
            --arg serviceName "$service_name" \
            --arg phase "$status_phase" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg workDirectory "$work_dir" \
            --arg topology "$work_dir/fabric.clab.yml" \
            --arg artifactDirectory "$artifact_dir" \
            --arg commandSurface "$service_name" \
            --arg result "$result" \
            --arg failureReason "$failure_reason" \
            '{
              serviceName: $serviceName,
              phase: $phase,
              timestamp: $timestamp,
              workDirectory: $workDirectory,
              topology: $topology,
              artifactDirectory: $artifactDirectory,
              commandSurface: $commandSurface,
              result: $result,
              failureReason: $failureReason
            }' > "$status_marker"
        }

        on_failure() {
          local status="$?"
          write_status failure "$phase" "exit status $status"
          exit "$status"
        }
        trap on_failure ERR

        mkdir -p "$work_dir" "$artifact_dir"
        write_status running "$phase" ""
        cat > "$work_dir/resolved-inventory-clab.nix" <<EOF
        if builtins.pathExists "$lab_dir/getResolvedInventory.nix" then
          import "$lab_dir/getResolvedInventory.nix" { renderer = "clab"; }
        else
          import "$lab_dir/inventory-clab.nix"
        EOF

        phase="source-eval"
        nix eval --impure --json --expr "import $lab_dir/intent.nix" \
          | jq -S . > "$artifact_dir/intent.json"

        nix eval --impure --json --expr "import $work_dir/resolved-inventory-clab.nix" \
          | jq -S . > "$artifact_dir/inventory.json"

        phase="model-build"
        OUTPUT_COMPILER_SIGNED_JSON="$artifact_dir/compiler.json" \
          nix run --show-trace "path:$compiler_repo#compile" -- \
            "$lab_dir/intent.nix" >/dev/null

        nix run --show-trace "path:$forwarding_repo#compile-and-build-forwarding-model" -- \
          "$lab_dir/intent.nix" \
          | jq -S . > "$artifact_dir/forwarding.json"

        nix run --show-trace "path:$cpm_repo#compile-and-build-control-plane-model" -- \
          "$lab_dir/intent.nix" \
          "$work_dir/resolved-inventory-clab.nix" \
          "$work_dir/cpm.json" >/dev/null
        jq -S . "$work_dir/cpm.json" > "$artifact_dir/control-plane.json"

        cp "$artifact_dir/inventory.json" "$work_dir/renderer-inventory.json"

        CLABGEN_RENDERER_INVENTORY_JSON="$work_dir/renderer-inventory.json" \
        CLABGEN_DEPLOYMENT_HOST="${deploymentHost}" \
          nix run --show-trace "path:$renderer_repo#generate-clab-config" -- \
            "$work_dir/cpm.json" \
            "$work_dir/fabric.clab.yml" \
            "$work_dir/vm-bridges-generated.nix" >/dev/null

        phase="artifact-bundle"
        python3 - "$work_dir" "$artifact_dir/rendered-host.json" <<'PY'
        import json
        import sys
        from pathlib import Path

        work_dir = Path(sys.argv[1])
        target = Path(sys.argv[2])
        payload = {
            "renderer": "network-renderer-containerlab-linux-backend",
            "artifactKind": "containerlab-rendered-host",
            "topology": str(work_dir / "fabric.clab.yml"),
            "bridgeModule": str(work_dir / "vm-bridges-generated.nix"),
            "networkArtifacts": str(work_dir / "network-artifacts"),
        }
        target.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        PY

        jq -S -n \
          --slurpfile intent "$artifact_dir/intent.json" \
          --slurpfile inventory "$artifact_dir/inventory.json" \
          --slurpfile compiler "$artifact_dir/compiler.json" \
          --slurpfile forwarding "$artifact_dir/forwarding.json" \
          --slurpfile controlPlane "$artifact_dir/control-plane.json" \
          --slurpfile renderedHost "$artifact_dir/rendered-host.json" \
          '{
            intent: $intent[0],
            globalInventory: $inventory[0],
            compilerOut: $compiler[0],
            forwardingOut: $forwarding[0],
            controlPlaneOut: $controlPlane[0],
            renderedHost: $renderedHost[0],
            hostName: "s-router-clab",
            system: "containerlab-linux",
            artifactContract: {
              sharedPath: "/persist/s-router-clab/live-validation/network-artifacts",
              containerPath: "/etc/network-artifacts"
            }
          }' > "$artifact_dir/debug-bundle.json"

        python3 - "$work_dir/vm-bridges-generated.nix" "$work_dir/setup-bridge-links.sh" <<'PY'
        import json
        import re
        import sys
        from pathlib import Path

        bridges = Path(sys.argv[1]).read_text()
        script_path = Path(sys.argv[2])
        quote = chr(39) * 2
        pattern = r"bridgeNetworks = builtins\.fromJSON " + quote + r"\n(.*)\n  " + quote + ";"
        match = re.search(pattern, bridges, re.S)
        if not match:
            raise SystemExit("missing bridgeNetworks JSON")

        bridge_networks = json.loads(match.group(1))
        bridges_match = re.search(r"bridges = \[\n(.*?)\n  \];", bridges, re.S)
        commands = ["set -euo pipefail"]
        bridge_names = set()
        if bridges_match:
            for bridge in re.findall(r'"([^"]+)"', bridges_match.group(1)):
                bridge_names.add(bridge)
        for bridge_name, bridge_data in sorted(bridge_networks.items()):
            if not isinstance(bridge_data, dict):
                continue
            bridge = bridge_data.get("bridge") or bridge_name
            if not isinstance(bridge, str) or not bridge:
                continue
            bridge_names.add(bridge)

        for bridge in sorted(bridge_names):
            commands.append(f"ip link show dev {bridge} >/dev/null 2>&1 || ip link add name {bridge} type bridge")
            commands.append(f"ip link set dev {bridge} up")

        for bridge_name, bridge_data in sorted(bridge_networks.items()):
            if not isinstance(bridge_data, dict):
                continue
            if bridge_data.get("mode") != "vlan":
                continue
            bridge = bridge_data.get("bridge") or bridge_name
            parent = bridge_data.get("parent")
            vlan = bridge_data.get("vlan")
            if not isinstance(bridge, str) or not isinstance(parent, str) or not isinstance(vlan, int):
                continue
            interface = f"{parent}.{vlan}"
            commands.append(f"ip link show dev {interface} >/dev/null 2>&1 || ip link add link {parent} name {interface} type vlan id {vlan}")
            commands.append(f"ip link set dev {interface} master {bridge}")
            commands.append(f"ip link set dev {interface} up")

        script_path.write_text("\n".join(commands) + "\n")
        PY
        cat > "$work_dir/verify-containerlab-deploy.sh" <<'VERIFY_CLAB'
        set -euo pipefail

        containers="$(docker ps --format '{{.Names}}' | grep '^clab-fabric-' || true)"
        test -n "$containers" || {
          echo "no clab-fabric containers are running after deploy" >&2
          exit 1
        }

        while IFS= read -r container; do
          count="$(
            timeout 10 docker exec "$container" sh -c \
              'find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo | wc -l'
          )" || {
            docker inspect "$container" >/dev/null 2>&1 || true
            echo "container $container did not answer non-loopback interface probe within 10s" >&2
            exit 1
          }
          if [ "$count" -lt 1 ]; then
            timeout 10 docker exec "$container" ip -br link || true
            echo "container $container has no non-loopback interfaces after deploy" >&2
            exit 1
          fi
        done <<EOF
        $containers
        EOF
        VERIFY_CLAB
        cat > "$work_dir/ensure-clab-tooling-image.sh" <<'ENSURE_CLAB_TOOLING'
        set -euo pipefail

        renderer_repo="''${CLAB_RENDERER_REPO:-${rendererRepo}}"
        tooling_build="$renderer_repo/docker-clab-frr-plus-tooling/build.sh"
        test -x "$tooling_build" || {
          echo "missing CLAB FRR tooling image builder: $tooling_build" >&2
          exit 1
        }
        "$tooling_build"
        ENSURE_CLAB_TOOLING
        chmod +x "$work_dir/ensure-clab-tooling-image.sh"

        phase="containerlab-deploy"
        flock /run/s-router-clab-render-live.lock bash -c "
          set -euo pipefail
          mkdir -p /run/s-router-clab /etc
          ln -sfn '$work_dir' /run/s-router-clab/live-current
          rm -rf /etc/network-artifacts
          ln -s '$artifact_dir' /etc/network-artifacts
          bash '$work_dir/ensure-clab-tooling-image.sh'
          containerlab destroy --all --cleanup --yes || true
          docker ps -aq --filter 'name=^clab-fabric-' | xargs -r docker rm -f
          bash '$work_dir/setup-bridge-links.sh'
          containerlab deploy -t '$work_dir/fabric.clab.yml' -d --reconfigure
          bash '$work_dir/verify-containerlab-deploy.sh'
        "
        phase="complete"
        write_status success "$phase" ""
      '';
    }
    else null;

in
{
  environment.systemPackages = lib.mkIf (hasAllRepos && s-router-clab-render-live != null) [
    s-router-clab-render-live
    pkgs.containerlab
  ];

  virtualisation.docker = lib.mkIf hasAllRepos {
    enable = true;
    autoPrune.enable = true;
  };

  environment.variables = lib.mkIf hasAllRepos {
    CLAB_RENDERER_REPO = toString rendererRepo;
    CLAB_NETWORK_LABS = toString labsRepo;
    CLAB_CONTROL_PLANE_MODEL = toString cpmRepo;
    CLAB_FRR_TOOLING_CACHE_DIR = "/persist/docker-image-cache/network-renderer-containerlab-linux-backend";
  };

  systemd.services.s-router-clab-render-live = lib.mkIf (hasAllRepos && s-router-clab-render-live != null) {
    description = "Render and deploy the s-router Containerlab topology";
    wantedBy = [ "multi-user.target" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [
      "docker.service"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30min";
    };
    script = ''
      exec ${s-router-clab-render-live}/bin/s-router-clab-render-live /persist/s-router-clab/live-boot
    '';
  };

  # ----- VLAN 4 upstream internet (persistent across reboots) -----
  # VLAN 4 is the emulated internet uplink: eth0.4 → br-uplink0 → container WAN
  # These netdevs/networks persist across reboots, complementing the
  # render-live service's containerlab-managed bridge infrastructure.
  systemd.network.netdevs = {
    "10-eth0.4" = {
      netdevConfig = {
        Kind = "vlan";
        Name = "eth0.4";
      };
      vlanConfig = {
        Id = 4;
      };
    };
    "50-br-uplink0" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-uplink0";
      };
    };

  };

  systemd.network.networks = {
    "10-eth0.4" = {
      matchConfig.Name = "eth0.4";
      linkConfig.ActivationPolicy = "always-up";
      networkConfig = {
        ConfigureWithoutCarrier = true;
        DHCP = "no";
        IPv6AcceptRA = false;
      };
    };
    "50-br-uplink0" = {
      matchConfig.Name = "br-uplink0";
      linkConfig.ActivationPolicy = "always-up";
      networkConfig = {
        Address = "10.11.0.1/24";
        DHCPServer = true;
        IPMasquerade = "both";
        IPv4Forwarding = true;
        IPv6Forwarding = true;
        ConfigureWithoutCarrier = true;
      };
    };
  };

  # nftables NAT masquerade for VLAN 4 internet egress
  # Applied on boot and persists across containerlab destroy cycles
  systemd.services.clab-vlan4-nat = {
    description = "CLAB VLAN 4 upstream NAT masquerade";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" "network-online.target" ];
    wants = [ "systemd-networkd.service" "network-online.target" ];
    path = [ pkgs.nftables pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Ensure masquerade on the uplink bridge for fabric internet access.
      # Docker manages table ip nat via iptables-nft — chain names are UPPERCASE.
      nft add rule ip nat POSTROUTING oifname br-uplink0 masquerade 2>/dev/null || true
      # Route fabric subnets back through the uplink bridge so return traffic
      # from VLAN4/internet reaches the core container.
      ip route replace 10.50.0.0/16 dev br-uplink0 2>/dev/null || true
      ip route replace 10.10.0.0/16 dev br-uplink0 2>/dev/null || true
    '';
    preStop = ''
      nft flush chain ip nat POSTROUTING 2>/dev/null || true
    '';
  };
}
