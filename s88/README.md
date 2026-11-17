# network-renderer-containerlab-linux-backend S88 Boundary

`network-renderer-containerlab-linux-backend` owns Containerlab/Linux artifact
projection from a validated canonical realization bundle
(FS-310-HDS-040-SDS-010-SMS-100). The bundle carries the released
`network-control-plane-artifact`; the renderer projects the enterprise/site
data inside that bundle and never reads a raw control-plane payload, intent,
inventory, or forwarding-model output.

## Enterprise

The renderer consumes the already scoped enterprise/site map carried by the
canonical bundle. It does not choose enterprises or sites.

## Site

Site-level rendering is coordinated by `generate-clab-config.py` and
`clabgen/site_validation.py`.

## Unit

Runtime target, interface, route, policy-rule, firewall, NAT, DNS, and host
bridge projections are implemented in `clabgen/cpm_runtime.py`,
`clabgen/cpm_runtime_wan.py`, `clabgen/cpm_transit.py`, and
`clabgen/models.py`.

## ControlModule

ControlModule-level renderer helpers live under `clabgen/` and
`clabgen/s88/`. They translate the canonical network envelope to
Containerlab/Linux syntax and must not infer topology, policy, DNS, NAT,
overlays, or host placement from names. `clabgen/canonical_bundle.py` is the
single input gate: it requires the bundle kind, the digest-bound validation,
the identity match and `network.data`, and rejects a raw `control_plane_model`
payload with a redacted `GAMP-MODEL-BOUNDARY-VIOLATION` diagnostic.

