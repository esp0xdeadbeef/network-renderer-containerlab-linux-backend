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

  addressFor = network: (ipv4For network).address or "198.18.0.1/24";
  poolOffsetFor = network: (ipv4For network).dhcpPoolOffset or 100;
  poolSizeFor = network: (ipv4For network).dhcpPoolSize or 100;
in
{
  natBridgeNames = builtins.attrNames natUplinks;

  isNatUplink = cfg: (cfg.mode or "") == "nat";

  networkConfigFor =
    cfg:
    lib.optionalAttrs ((cfg.mode or "") == "nat") {
      Address = [ (addressFor cfg) ];
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
