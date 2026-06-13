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
      # CPM_GAP: DHCPServer and IPMasquerade are hardcoded for NAT bridge
      # networks. The CPM does not yet emit explicitRole.dhcpServer or
      # bridgeControlConfig.masquerade for vm-bridge NAT networks.
      # Trace: FS-380-HDS-010-SDS-010-SMS-060
      # CPM_GAP: address, dhcpPoolOffset, dhcpPoolSize — also hardcoded
      # defaults before CMC fix. Now throw. Trace: FS-310.
      DHCPServer = true;
      IPv4Forwarding = true;
      IPMasquerade = "ipv4";
    };

  dhcpServerConfigFor =
    cfg:
    lib.optionalAttrs ((cfg.mode or "") == "nat") {
      EmitDNS = false;
      PoolOffset = poolOffsetFor cfg;
      PoolSize = poolSizeFor cfg;
    };
}
