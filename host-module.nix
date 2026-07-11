{ config
, lib
, pkgs
, clabDeploymentHost ? null
, clabCpmJsonPath ? null
, clabRendererInventoryJsonPath ? null
, containerlabLinuxRendererInput ? {}
, containerlabLinuxRendererSelf  ? null
, containerlabLinuxGenerateClabConfig ? null
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
  generateClabConfig =
    if containerlabLinuxGenerateClabConfig == null then null else containerlabLinuxGenerateClabConfig;

  # Renderer requires: renderer repo + pre-built CPM JSON + renderer inventory JSON.
  # No compiler-chain repos or intent/inventory files are needed.
  hasInputs =
    rendererRepo != null
    && generateClabConfig != null
    && cpmJsonPath != null
    && rendererInventoryJsonPath != null;

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
        pkgs.procps
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
        deploy_timeout_seconds="''${CLAB_DEPLOY_TIMEOUT_SECONDS:-900}"
        deploy_idle_timeout_seconds="''${CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS:-180}"
        cleanup_timeout_seconds="''${CLAB_CLEANUP_TIMEOUT_SECONDS:-120}"
        deploy_max_workers="''${CLAB_DEPLOY_MAX_WORKERS:-1}"
        containerlab_api_timeout="''${CLAB_CONTAINERLAB_API_TIMEOUT:-10m}"

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
        if [[ -f "$renderer_inventory_json" ]]; then
          echo "Using renderer inventory: $renderer_inventory_json" >&2
          cp "$renderer_inventory_json" "$work_dir/renderer-inventory.json"
          cp "$renderer_inventory_json" "$artifact_dir/inventory.json"
        else
          echo "Renderer inventory JSON not found, will rely on CPM fallback (endpointInventory): $renderer_inventory_json" >&2
        fi
        cp "$cpm_json" "$work_dir/cpm.json"
        cp "$cpm_json" "$artifact_dir/control-plane.json"
        jq -S '.forwardingOut // {}' "$cpm_json" > "$artifact_dir/forwarding.json"
        jq -S '.compilerOut // {}' "$cpm_json" > "$artifact_dir/compiler.json"

        phase="render"
        CLABGEN_RENDERER_INVENTORY_JSON="$renderer_inventory_json" \
        CLABGEN_DEPLOYMENT_HOST="$deployment_host" \
          ${generateClabConfig}/bin/generate-clab-config \
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

        PYTHONPATH="$renderer_repo" python3 -m clabgen.s88.CM.route_materialization_artifact \
          "$cpm_json" \
          "$deployment_host" \
          "$artifact_dir/clab-route-materialization.json"

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
        commands = [
            "set -euo pipefail",
            "for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.bridge.bridge-nf-call-arptables; do sysctl -w \"$key=0\" >/dev/null 2>&1 || true; done",
        ]
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

        topology_file="''${1:?topology file required}"
        containers="$(docker ps --format '{{.Names}}' | grep '^clab-fabric-' || true)"
        test -n "$containers" || {
          if grep -Eq '^[[:space:]]+nodes:[[:space:]]*\{\}[[:space:]]*$' "$topology_file"; then
            echo "empty containerlab topology; no containers expected"
            exit 0
          fi
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
          health="$(
            timeout 10 docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container"
          )" || {
            echo "container $container health status could not be inspected" >&2
            exit 1
          }
          case "$health" in
            healthy|none)
              ;;
            *)
              echo "container $container health check is $health" >&2
              exit 1
              ;;
          esac
        done <<EOF
        $containers
        EOF
        VERIFY_CLAB

        cat > "$work_dir/retry-wan-dhcp.sh" <<'RETRY_WAN_DHCP'
        set -euo pipefail

        containers="$(docker ps --format '{{.Names}}' | grep '^clab-fabric-' || true)"
        test -n "$containers" || exit 0

        while IFS= read -r container; do
          test -n "$container" || continue
          docker exec "$container" sh -eu -c '
            for path in /sys/class/net/u*; do
              test -e "$path" || continue
              iface="''${path##*/}"
              case "$iface" in
                u*[!0-9]*)
                  continue
                  ;;
              esac
              ip link set "$iface" up
              if ip -4 addr show dev "$iface" | grep -q " inet "; then
                continue
              fi
              test -x /sbin/udhcpc || continue
              timeout 12 udhcpc -q -n -i "$iface" -s /bin/true >/dev/null 2>&1 || true
            done
          '
        done <<EOF
        $containers
        EOF
        RETRY_WAN_DHCP

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

        cat > "$work_dir/deploy-containerlab-on-host.sh" <<'DEPLOY_CLAB_HOST'
        set -euo pipefail

        topology_file="''${CLAB_HOST_TOPOLOGY:?missing CLAB_HOST_TOPOLOGY}"
        deploy_log="''${CLAB_HOST_DEPLOY_LOG:?missing CLAB_HOST_DEPLOY_LOG}"
        deploy_timeout_seconds="''${CLAB_DEPLOY_TIMEOUT_SECONDS:-900}"
        deploy_idle_timeout_seconds="''${CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS:-180}"
        deploy_max_workers="''${CLAB_DEPLOY_MAX_WORKERS:-1}"
        containerlab_api_timeout="''${CLAB_CONTAINERLAB_API_TIMEOUT:-10m}"

        stop_containerlab_deploy() {
          local deploy_pid="$1"
          if ! kill -- "-''${deploy_pid}" &>/dev/null; then
            if ! kill "''${deploy_pid}" &>/dev/null; then
              :
            fi
          fi
          sleep 1
          if ! kill -KILL -- "-''${deploy_pid}" &>/dev/null; then
            if ! kill -KILL "''${deploy_pid}" &>/dev/null; then
              :
            fi
          fi
        }

        run_containerlab_deploy_once() {
          local deploy_pipe
          local deploy_fd
          local deploy_pid
          local line
          local rc
          local saw_erro=0
          local saw_idle_timeout=0
          local message

          : > "$deploy_log"
          deploy_pipe="$(mktemp -u "''${TMPDIR:-/tmp}/s-router-clab-deploy.XXXXXX.pipe")"
          mkfifo "$deploy_pipe"
          if command -v setsid >/dev/null 2>&1; then
            setsid timeout --foreground "$deploy_timeout_seconds" \
              containerlab deploy -t "$topology_file" -d --reconfigure --timeout "$containerlab_api_timeout" --max-workers "$deploy_max_workers" \
              >"$deploy_pipe" 2>&1 &
          else
            timeout --foreground "$deploy_timeout_seconds" \
              containerlab deploy -t "$topology_file" -d --reconfigure --timeout "$containerlab_api_timeout" --max-workers "$deploy_max_workers" \
              >"$deploy_pipe" 2>&1 &
          fi
          deploy_pid="$!"
          exec {deploy_fd}<"$deploy_pipe"

          while true; do
            if ! IFS= read -r -t "$deploy_idle_timeout_seconds" line <&''${deploy_fd}; then
              if kill -0 "$deploy_pid" >/dev/null 2>&1; then
                saw_idle_timeout=1
                message="containerlab deploy produced no output for ''${deploy_idle_timeout_seconds}s; refusing readiness marker"
                printf '%s\n' "$message" >&2
                printf '%s\n' "$message" >>"$deploy_log"
                stop_containerlab_deploy "$deploy_pid"
              fi
              break
            fi
            printf '%s\n' "$line"
            printf '%s\n' "$line" >>"$deploy_log"
            if [[ "$line" =~ (^|[[:space:]])ERRO([[:space:]]|$) ]]; then
              saw_erro=1
              printf 'containerlab deploy emitted ERRO lines; refusing readiness marker\n' >&2
              stop_containerlab_deploy "$deploy_pid"
              break
            fi
          done

          exec {deploy_fd}<&-
          wait "$deploy_pid"
          rc="$?"
          rm -f "$deploy_pipe"

          if ((saw_erro == 1)); then
            return 66
          elif ((saw_idle_timeout == 1)); then
            return 67
          fi
          return "$rc"
        }

        set +e
        run_containerlab_deploy_once
        deploy_rc="$?"
        set -e

        if ((deploy_rc == 66)); then
          exit 1
        elif ((deploy_rc == 67)); then
          exit 1
        elif ((deploy_rc != 0)); then
          exit "$deploy_rc"
        fi

        if grep -Eq '(^|[[:space:]])ERRO([[:space:]]|$)' "$deploy_log"; then
          echo 'containerlab deploy emitted ERRO lines; refusing readiness marker' >&2
          exit 1
        fi
        DEPLOY_CLAB_HOST
        chmod +x "$work_dir/deploy-containerlab-on-host.sh"

        phase="containerlab-deploy"
        flock /run/s-router-clab-render-live.lock bash -c "
          set -euo pipefail
          mkdir -p /run/s-router-clab /etc
          ln -sfn '$work_dir' /run/s-router-clab/live-current
          rm -rf /etc/network-artifacts
          ln -s '$artifact_dir' /etc/network-artifacts
          bash '$work_dir/ensure-clab-tooling-image.sh'
          timeout --foreground '$cleanup_timeout_seconds' containerlab destroy --all --cleanup --yes || true
          docker ps -aq --filter 'name=^clab-fabric-' | xargs -r docker rm -f
          bash '$work_dir/setup-bridge-links.sh'
          deploy_log='$work_dir/containerlab-deploy.log'
          CLAB_HOST_TOPOLOGY='$work_dir/fabric.clab.yml' \
            CLAB_HOST_DEPLOY_LOG=\"\$deploy_log\" \
            CLAB_DEPLOY_TIMEOUT_SECONDS='$deploy_timeout_seconds' \
            CLAB_DEPLOY_IDLE_TIMEOUT_SECONDS='$deploy_idle_timeout_seconds' \
            CLAB_DEPLOY_MAX_WORKERS='$deploy_max_workers' \
            CLAB_CONTAINERLAB_API_TIMEOUT='$containerlab_api_timeout' \
            bash '$work_dir/deploy-containerlab-on-host.sh'
          bash '$work_dir/setup-bridge-links.sh'
          bash '$work_dir/retry-wan-dhcp.sh'
          bash '$work_dir/verify-containerlab-deploy.sh' '$work_dir/fabric.clab.yml'
        "
        phase="complete"
        write_status success "$phase" ""
      '';
    }
    else null;

in
{
  networking.useNetworkd = true;
  systemd.network.enable = true;
  networking.useDHCP = false;

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
      "sops-nix.service"
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

  # ----- Management VLAN2 (persistent across reboots) -----
  # VLAN2 provides management network access via DHCP on eth0.
  # Read from CPM deployment hosts -> uplinks.management (URS: inventory → CPM → renderer)
  systemd.network.netdevs = {
    "10-eth0.2" = lib.mkIf (containerlabLinuxRendererInput ? managementVlan && containerlabLinuxRendererInput.managementVlan != null) {
      netdevConfig = {
        Kind = "vlan";
        Name = "eth0.2";
      };
      vlanConfig = {
        Id = 2;
      };
    };
    "20-vlan2" = lib.mkIf (containerlabLinuxRendererInput ? managementVlan && containerlabLinuxRendererInput.managementVlan != null) {
      netdevConfig = {
        Kind = "bridge";
        Name = "vlan2";
      };
    };
    # ----- VLAN 4 upstream internet (persistent across reboots) -----
    # VLAN 4 is the emulated internet uplink: eth0.4 → br-uplink0 → container WAN
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
    # Management VLAN2: parent interface eth0 with VLAN2 tag
    "10-eth0" = lib.mkIf (containerlabLinuxRendererInput ? managementVlan && containerlabLinuxRendererInput.managementVlan != null) {
      matchConfig.Name = "eth0";
      linkConfig.ActivationPolicy = "always-up";
      networkConfig = {
        ConfigureWithoutCarrier = true;
        DHCP = "no";
        LinkLocalAddressing = "no";
        VLAN = [ "eth0.2" ];
      };
    };
    # Management VLAN2: eth0.2 attach to vlan2 bridge
    "20-eth0.2" = lib.mkIf (containerlabLinuxRendererInput ? managementVlan && containerlabLinuxRendererInput.managementVlan != null) {
      matchConfig.Name = "eth0.2";
      linkConfig.ActivationPolicy = "always-up";
      networkConfig = {
        ConfigureWithoutCarrier = true;
        DHCP = "no";
        LinkLocalAddressing = "no";
        Bridge = "vlan2";
      };
    };
    # Management VLAN2: vlan2 bridge with DHCP
    "30-vlan2" = lib.mkIf (containerlabLinuxRendererInput ? managementVlan && containerlabLinuxRendererInput.managementVlan != null) {
      matchConfig.Name = "vlan2";
      linkConfig.ActivationPolicy = "always-up";
      networkConfig = {
        ConfigureWithoutCarrier = true;
        DHCP = "ipv4";
        LinkLocalAddressing = "no";
        IPv6AcceptRA = "no";
      };
    };
    # VLAN4: eth0.4 interface
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
