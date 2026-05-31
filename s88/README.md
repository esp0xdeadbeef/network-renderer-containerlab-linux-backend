# network-renderer-containerlab-linux-backend S88 Boundary

`network-renderer-containerlab-linux-backend` owns Containerlab/Linux artifact
projection from explicit CPM input.

## Enterprise

The renderer consumes already scoped CPM enterprise/site data. It does not
choose enterprises or sites.

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
`clabgen/s88/`. They translate CPM contracts to Containerlab/Linux syntax and
must not infer topology, policy, DNS, NAT, overlays, or host placement from
names.

