# ./vm.nix
{
  config,
  pkgs,
  lib,
  ...
}:

let
  generatedBridgesFile =
    let
      fromEnv = builtins.getEnv "CLAB_VM_BRIDGES_FILE";
    in
    if fromEnv != "" then builtins.toPath fromEnv else ./vm-bridges-generated.nix;

  generated = import generatedBridgesFile { inherit lib; };
  vmMemorySize =
    let
      fromEnv = builtins.getEnv "CLAB_VM_MEMORY_MB";
    in
    if fromEnv != "" then builtins.fromJSON fromEnv else 1024 * 24;
  vmCores =
    let
      fromEnv = builtins.getEnv "CLAB_VM_CORES";
    in
    if fromEnv != "" then builtins.fromJSON fromEnv else 22;

  bridges = generated.bridges;
  bridgeNetworks = lib.mapAttrs (
    name: network:
    if builtins.isAttrs network then network // { bridge = network.bridge or name; } else network
  ) (generated.bridgeNetworks or { });
  bridgeNames = lib.unique (bridges ++ builtins.attrNames bridgeNetworks);
  bridgeNetworkNames = builtins.attrNames bridgeNetworks;
  physicalUplinks = lib.filterAttrs (
    _name: uplink:
      builtins.isAttrs uplink
      && builtins.isString (uplink.bridge or null)
      && builtins.isString (uplink.parent or null)
      && builtins.isString (uplink.mode or null)
  ) bridgeNetworks;
  physicalUplinkNames = builtins.attrNames physicalUplinks;

  vlanIfNameFor = uplink: "${uplink.parent}.${toString uplink.vlan}";

  vlanUplinkNames = lib.filter (
    name:
      let uplink = physicalUplinks.${name};
      in (uplink.mode or "") == "vlan" && builtins.isInt (uplink.vlan or null)
  ) physicalUplinkNames;

  parentIfNames = lib.unique (
    lib.filter builtins.isString (map (name: physicalUplinks.${name}.parent or null) physicalUplinkNames)
  );

  mkNetdev = name: {
    netdevConfig = {
      Name = name;
      Kind = "bridge";
    };
  };

  mkBridgeNetwork = name: {
    matchConfig.Name = name;
    linkConfig = {
      ActivationPolicy = "always-up";
      RequiredForOnline = "no";
    };
    networkConfig = {
      ConfigureWithoutCarrier = true;
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
      DHCP =
        let cfg = bridgeNetworks.${name} or { };
        in if name == "vlan2" || cfg.name or null == "management" then "ipv4" else "no";
    };
    dhcpV4Config = lib.optionalAttrs (name == "vlan2") { UseDNS = false; };
  };

  vlanNetdevs = builtins.listToAttrs (
    map (
      name:
      let
        uplink = physicalUplinks.${name};
        vlanIfName = vlanIfNameFor uplink;
      in
      {
        name = "11-${vlanIfName}";
        value = {
          netdevConfig = {
            Name = vlanIfName;
            Kind = "vlan";
          };
          vlanConfig.Id = uplink.vlan;
        };
      }
    ) vlanUplinkNames
  );

  parentNetworks = builtins.listToAttrs (
    map (
      parentIf:
      let
        vlanChildren = map (
          name: vlanIfNameFor physicalUplinks.${name}
        ) (lib.filter (name: physicalUplinks.${name}.parent == parentIf) vlanUplinkNames);
      in
      {
        name = "20-${parentIf}";
        value = {
          matchConfig.Name = parentIf;
          linkConfig = {
            ActivationPolicy = "always-up";
            RequiredForOnline = "no";
          };
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
            DHCP = lib.mkIf (parentIf == "eth0") "ipv4";
            VLAN = vlanChildren;
          };
          dhcpV4Config = lib.optionalAttrs (parentIf == "eth0") { UseDNS = false; };
        };
      }
    ) parentIfNames
  );

  vlanAttachmentNetworks = builtins.listToAttrs (
    map (
      name:
      let
        uplink = physicalUplinks.${name};
        vlanIfName = vlanIfNameFor uplink;
      in
      {
        name = "21-${vlanIfName}";
        value = {
          matchConfig.Name = vlanIfName;
          linkConfig = {
            ActivationPolicy = "always-up";
            RequiredForOnline = "no";
          };
          networkConfig = {
            Bridge = uplink.bridge;
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          };
        };
      }
    ) vlanUplinkNames
  );
in
{
  system.stateVersion = "25.11";

  networking.useNetworkd = true;

  networking.useDHCP = true;
  services.resolved.enable = true;

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;

    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;

    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;
  };

  boot.kernelModules = [ "br_netfilter" ];

  systemd.network.netdevs = (lib.genAttrs bridgeNames mkNetdev) // vlanNetdevs;
  systemd.network.networks =
    (lib.genAttrs bridgeNames mkBridgeNetwork)
    // parentNetworks
    // vlanAttachmentNetworks;

  virtualisation.docker.enable = true;

  environment.systemPackages = with pkgs; [
    containerlab
    iproute2
    jq
    gron
    tmux
    neovim
    tcpdump
    traceroute
    nftables
  ];

  networking.nftables.enable = true;

  users.users.root.shell = pkgs.bash;

  virtualisation.memorySize = vmMemorySize;
  virtualisation.cores = vmCores;
  environment.etc.hosts.enable = false;
  services.openssh.enable = true;

  nixos-shell.mounts = {
    cache = "none";
  };
}
