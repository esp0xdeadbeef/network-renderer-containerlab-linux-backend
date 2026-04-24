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

  bridges = generated.bridges;

  mkNetdev = name: {
    netdevConfig = {
      Name = name;
      Kind = "bridge";
    };
  };

  mkNetwork = name: {
    matchConfig.Name = name;
    networkConfig = {
      ConfigureWithoutCarrier = true;
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };
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

  systemd.network.netdevs = lib.genAttrs bridges mkNetdev;
  systemd.network.networks = lib.genAttrs bridges mkNetwork;

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

  virtualisation.memorySize = 1024 * 24;
  virtualisation.cores = 22;
  environment.etc.hosts.enable = false;
  services.openssh.enable = true;

  nixos-shell.mounts = {
    cache = "none";
  };
}
