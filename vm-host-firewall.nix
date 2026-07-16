# ./vm-host-firewall.nix
# FS-310-HDS-020-SDS-010-SMS-200: VM host-firewall enablement must trace to an
# explicit controlled source decision (renderer inventory
# `containerlab.hostFirewall`, carried into the generated bridges artifact as
# `hostFirewall`). The CLAB VM/bridge module must not disable or omit the host
# firewall as a VM/test-placement convenience default. When CPM and renderer
# inventory are both silent, this resolver fails closed with a rejection
# diagnostic instead of substituting a default.
{ generated }:
let
  trace = "FS-310-HDS-020-SDS-010-SMS-200";
  hostFirewall = generated.hostFirewall or null;
in
if hostFirewall == null then
  throw ("vm-host-firewall: missing explicit host-firewall authority ("
    + trace
    + "): renderer inventory containerlab.hostFirewall.enable must decide host"
    + " firewall enablement; the CLAB VM module must not default to"
    + " networking.firewall.enable = false — VM/test placement is not authority")
else if !(builtins.isAttrs hostFirewall)
  || !(hostFirewall ? enable)
  || !(builtins.isBool hostFirewall.enable) then
  throw ("vm-host-firewall: invalid host-firewall authority record ("
    + trace
    + "): expected { enable = <bool>; ... } from renderer inventory"
    + " containerlab.hostFirewall; refusing implicit host-firewall decision")
else
  hostFirewall.enable
