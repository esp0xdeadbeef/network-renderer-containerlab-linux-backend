# FS-310-HDS-020-SDS-010-SMS-040 and FS-320-HDS-010-SDS-010-SMS-030:
# VM host eth0 is an explicit platform parent interface for test substrate
# bridge/VLAN materialization, not a renderer fallback.
{ lib
, generated
,
}:

let
  bridges = generated.bridges;
  rawBridgeNetworks = generated.bridgeNetworks or { };
  bridgeNetworks = builtins.listToAttrs (
    lib.mapAttrsToList
      (
        name: network:
          let
            normalized =
              if builtins.isAttrs network then
                network // {
                  # CMC: FS-310 — no bridge name inference. CPM must provide bridge field.
                  bridge = network.bridge
                    or throw "vm-network: missing CPM bridge field for network '${name}' — CPM must provide bridge name, renderer must not infer from inventory name";
                  inventoryName = name;
                }
              else
                network;
          in
          {
            name = normalized.bridge
              or throw "vm-network: bridge field missing after normalization for '${name}' — CPM must provide bridge name";
            value = normalized;
          }
      )
      rawBridgeNetworks
  );
  bridgeNames = lib.unique (bridges ++ builtins.attrNames bridgeNetworks);
  physicalUplinks = lib.filterAttrs
    (
      _name: uplink:
        builtins.isAttrs uplink
        && builtins.isString (uplink.bridge or null)
        && builtins.isString (uplink.parent or null)
        && builtins.isString (uplink.mode or null)
    )
    bridgeNetworks;
  physicalUplinkNames = builtins.attrNames physicalUplinks;

  vlanIfNameFor = uplink: "${uplink.parent}.${toString uplink.vlan}";

  vlanUplinkNames = lib.filter
    (
      name:
      let
        uplink = physicalUplinks.${name};
      in
      (uplink.mode or "") == "vlan" && builtins.isInt (uplink.vlan or null)
    )
    physicalUplinkNames;

  parentIfNames = lib.unique (
    lib.filter builtins.isString (map (name: physicalUplinks.${name}.parent or null) physicalUplinkNames)
  );

  mkNetdev = name: {
    netdevConfig = {
      Name = name;
      Kind = "bridge";
    };
  };

  nat = import ./vm-network-nat.nix { inherit lib bridgeNetworks; };

  mkBridgeNetwork =
    name:
    let
      cfg = bridgeNetworks.${name} or { };
    in
    {
      matchConfig.Name = name;
      linkConfig = {
        ActivationPolicy = "always-up";
        RequiredForOnline = "no";
      };
      networkConfig = {
        ConfigureWithoutCarrier = true;
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        DHCP = if name == "vlan2" || cfg.name or null == "management" then "ipv4" else "no";
      } // nat.networkConfigFor cfg;
      dhcpV4Config = lib.optionalAttrs (name == "vlan2") { UseDNS = false; };
      dhcpServerConfig = nat.dhcpServerConfigFor cfg;
    };

  vlanNetdevs = builtins.listToAttrs (
    map
      (
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
      )
      vlanUplinkNames
  );

  parentNetworks = builtins.listToAttrs (
    map
      (
        parentIf:
        let
          vlanChildren = map
            (
              name: vlanIfNameFor physicalUplinks.${name}
            )
            (lib.filter (name: physicalUplinks.${name}.parent == parentIf) vlanUplinkNames);
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
      )
      parentIfNames
  );

  vlanAttachmentNetworks = builtins.listToAttrs (
    map
      (
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
      )
      vlanUplinkNames
  );
in
{
  inherit
    bridgeNames
    mkNetdev
    mkBridgeNetwork
    parentNetworks
    vlanAttachmentNetworks
    vlanNetdevs
    ;
  inherit (nat) natBridgeNames;
}
