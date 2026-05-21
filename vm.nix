# ./vm.nix
{ config
, pkgs
, lib
, ...
}:

let
  generatedBridgesFile =
    let
      fromEnv = builtins.getEnv "CLAB_VM_BRIDGES_FILE";
    in
    if fromEnv != "" then builtins.toPath fromEnv else ./vm-bridges-generated.nix;

  generated = import generatedBridgesFile { inherit lib; };
  vmNetwork = import ./vm-network.nix { inherit lib generated; };
  natBridgeNames = vmNetwork.natBridgeNames or [ ];
  natBridgeSet = "{ " + lib.concatMapStringsSep ", " (name: ''"${name}"'') natBridgeNames + " }";
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

  systemd.network.netdevs =
    (lib.genAttrs vmNetwork.bridgeNames vmNetwork.mkNetdev)
    // vmNetwork.vlanNetdevs;
  systemd.network.networks =
    (lib.genAttrs vmNetwork.bridgeNames vmNetwork.mkBridgeNetwork)
    // vmNetwork.parentNetworks
    // vmNetwork.vlanAttachmentNetworks;

  virtualisation.docker.enable = true;
  networking.firewall.enable = false;

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
  networking.nftables.ruleset = lib.optionalString (natBridgeNames != [ ]) ''
    table ip clab_vm_nat {
      chain forward {
        type filter hook forward priority filter; policy accept;
        iifname ${natBridgeSet} oifname "eth0" accept
        iifname "eth0" oifname ${natBridgeSet} ct state established,related accept
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname ${natBridgeSet} oifname "eth0" masquerade
      }
    }
  '';

  users.users.root.shell = pkgs.bash;

  virtualisation.memorySize = vmMemorySize;
  virtualisation.cores = vmCores;
  environment.etc.hosts.enable = false;
  services.openssh.enable = true;

  nixos-shell.mounts = {
    cache = "none";
  };
}
