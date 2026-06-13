{ lib
, bridgeNetworks
,
}:

let
  natUplinks = lib.filterAttrs
    (
      _name: uplink: builtins.isAttrs uplink && (uplink.mode or "") == "nat"
    )
    bridgeNetworks;

  ipv4For = network: network.ipv4 or { };

  # CMC: FS-310 — no hardcoded fallbacks. CPM must provide these fields.
  # CPM_GAP: ipv4.address, ipv4.dhcpPoolOffset, ipv4.dhcpPoolSize are not
  # yet emitted by CPM for bridge networks. Until CPM emits them, NAT
  # bridge networks will throw at evaluation time.
  addressFor = network: (ipv4For network).address
    or throw "vm-network-nat: missing CPM ipv4.address for NAT network ${network.bridge or network.inventoryName or "unknown"} — CPM must provide";
  poolOffsetFor = network: (ipv4For network).dhcpPoolOffset
    or throw "vm-network-nat: missing CPM ipv4.dhcpPoolOffset for NAT network ${network.bridge or network.inventoryName or "unknown"} — CPM must provide";
  poolSizeFor = network: (ipv4For network).dhcpPoolSize
    or throw "vm-network-nat: missing CPM ipv4.dhcpPoolSize for NAT network ${network.bridge or network.inventoryName or "unknown"} — CPM must provide";
in
{
  natBridgeNames = builtins.attrNames natUplinks;

  isNatUplink = cfg: (cfg.mode or "") == "nat";

  networkConfigFor =
    cfg:
    lib.optionalAttrs ((cfg.mode or "") == "nat") {
      Address = [ (addressFor cfg) ];
      # CMC: FS-310-HDS-010-SDS-010-SMS-200 — no unconditional DHCPServer/IPMasquerade.
      # CPM_GAP: DHCPServer should trace to CPM wanPool.dhcpServer.
      # CPM_GAP: IPMasquerade should trace to CPM natIntent.masqueradeInterfaces.
      # CPM does not yet emit these for vm-bridge NAT networks.
      # Reference: FS-380-HDS-010-SDS-010-SMS-060.
      DHCPServer =
        if cfg ? dhcpServer then
          cfg.dhcpServer
        else
          throw "vm-network-nat: DHCPServer requires CPM wanPool.dhcpServer for NAT network ${cfg.bridge or cfg.inventoryName or "unknown"} — CPM_GAP: CPM does not yet emit dhcpServer for bridge networks";
      IPv4Forwarding = true;
      IPMasquerade =
        if cfg ? masquerade then
          cfg.masquerade
        else
          throw "vm-network-nat: IPMasquerade requires CPM natIntent.masqueradeInterfaces for NAT network ${cfg.bridge or cfg.inventoryName or "unknown"} — CPM_GAP: CPM does not yet emit masquerade authorization for bridge networks";
    };

  dhcpServerConfigFor =
    cfg:
    lib.optionalAttrs ((cfg.mode or "") == "nat") {
      EmitDNS = false;
      PoolOffset = poolOffsetFor cfg;
      PoolSize = poolSizeFor cfg;
    };
}
