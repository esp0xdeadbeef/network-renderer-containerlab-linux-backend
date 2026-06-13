{ config
, lib
, pkgs
, clabDeploymentHost ? null
, clabCpmJsonPath ? null
, clabRendererInventoryJsonPath ? null
, containerlabLinuxRendererSelf  ? null
, ...
}:
let
  inherit (lib) mkDefault mkForce optionalString;

  # CMC: FS-310 — no hardcoded defaults. Throw when required inputs are missing.
  # All string values passed as separate _module.args keys to avoid NixOS
  # attrset corruption (store paths and empty strings get extracted).
  deploymentHost =
    if clabDeploymentHost != null then clabDeploymentHost
    else throw "host-module: missing required input: clabDeploymentHost";

  # Pre-built CPM artifacts (produced upstream by the compiler pipeline).
  # The renderer must NOT import intent.nix or inventory-clab.nix directly.
  cpmJsonPath =
    if clabCpmJsonPath != null then clabCpmJsonPath
    else throw "host-module: missing required input: clabCpmJsonPath";

  rendererInventoryJsonPath =
    if clabRendererInventoryJsonPath != null then clabRendererInventoryJsonPath
    else throw "host-module: missing required input: clabRendererInventoryJsonPath";

  rendererRepo = if containerlabLinuxRendererSelf == null then null else containerlabLinuxRendererSelf;

  # Renderer requires: renderer repo + pre-built CPM JSON + renderer inventory JSON.
  # No compiler-chain repos or intent/inventory files are needed.
  hasInputs = rendererRepo != null && cpmJsonPath != null && rendererInventoryJsonPath != null;

  s-router-clab-render-live =
    if hasInputs then
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
        pkgs.python3
        pkgs.systemd
        pkgs.util-linux
      ];
      text = ''
        set -euo pipefail

        export NIX_CONFIG="experimental-features = nix-command flakes"

        renderer_repo="${rendererRepo}"
        work_dir="''${1:-/persist/s-router-clab/live-$(date +%s)}"
        artifact_dir="$work_dir/network-artifacts"
        status_marker="$work_dir/s-router-clab-render-live-status.json"
        service_name="s-router-clab-render-live"
        phase="render-start"

        cpm_json="${cpmJsonPath}"
        renderer_inventory_json="${rendererInventoryJsonPath}"
        deployment_host="${deploymentHost}"

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

        # Validate pre-built CPM inputs (produced upstream by the compiler).
        [[ -f "$cpm_json" ]] || {
          echo "CPM JSON not found: $cpm_json" >&2
          exit 1
        }
        [[ -f "$renderer_inventory_json" ]] || {
          echo "Renderer inventory JSON not found: $renderer_inventory_json" >&2
          exit 1
        }

        phase="render"
        CLABGEN_RENDERER_INVENTORY_JSON="$renderer_inventory_json" \
        CLABGEN_DEPLOYMENT_HOST="$deployment_host" \
          nix run --show-trace "path:$renderer_repo#generate-clab-config" -- \
            "$cpm_json" \
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
  environment.systemPackages = lib.mkIf (hasInputs && s-router-clab-render-live != null) [
    s-router-clab-render-live
    pkgs.containerlab
  ];

  virtualisation.docker = lib.mkIf hasInputs {
    enable = true;
    autoPrune.enable = true;
  };

  environment.variables = lib.mkIf hasInputs {
    CLAB_RENDERER_REPO = toString rendererRepo;
    CLAB_FRR_TOOLING_CACHE_DIR = "/persist/docker-image-cache/network-renderer-containerlab-linux-backend";
  };

  systemd.services.s-router-clab-render-live = lib.mkIf (hasInputs && s-router-clab-render-live != null) {
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
        # CMC: FS-310-HDS-010-SDS-010-SMS-200 — no unconditional DHCPServer/IPMasquerade.
        # URS L97: host configuration stays thin — bridgeControl values are imported,
        # not computed from raw CPM. The consumer must provide CPM-derived
        # bridgeControl as rendererInput, per FS-310 fail-closed contract.
        # CPM_GAP: CPM does not yet emit wanPool.dhcpServer or
        # natIntent.masqueradeInterfaces for host-level bridge configuration.
        # The br-uplink0 bridge carries VLAN4 upstream internet traffic;
        # containers connected to it need DHCP and NAT masquerade to reach
        # the internet through the host's eth0.4 interface.
        DHCPServer =
          if containerlabLinuxRendererInput ? bridgeControl
             && containerlabLinuxRendererInput.bridgeControl ? dhcpServer then
            containerlabLinuxRendererInput.bridgeControl.dhcpServer
          else
            throw "host-module: DHCPServer requires containerlabLinuxRendererInput.bridgeControl.dhcpServer — CPM_GAP: consumer must provide CPM-derived bridgeControl.dhcpServer for br-uplink0";
        IPMasquerade =
          if containerlabLinuxRendererInput ? bridgeControl
             && containerlabLinuxRendererInput.bridgeControl ? masquerade then
            containerlabLinuxRendererInput.bridgeControl.masquerade
          else
            throw "host-module: IPMasquerade requires containerlabLinuxRendererInput.bridgeControl.masquerade — CPM_GAP: consumer must provide CPM-derived bridgeControl.masquerade for br-uplink0";
        IPv4Forwarding = true;
        IPv6Forwarding = true;
        ConfigureWithoutCarrier = true;
      };
    };
  };
}
