# network-renderer-containerlab-linux-backend

`network-renderer-containerlab-linux-backend` emits Containerlab/Linux backend
artifacts from one validated canonical network-realization bundle and, when
required, one normalized CLAB platform-binding bundle.

It is an emission stage only.

Pipeline position: this repository is downstream of canonical realization and
schema validation and upstream of Containerlab/Linux backend artifacts.

Migration, deviation, exception, transition, or temporary compatibility behavior
must be explicit in the README, tests, and owning layer before it is accepted.

```text
network-control-plane-model -> network-realization-model -> schema validation -> network-renderer-containerlab-linux-backend
```

## Spec Chain

This renderer materializes Containerlab/Linux backend artifacts from a
validated canonical realization bundle.
All behavior requirements originate from the FS spec chain.

### Owning Chain: Renderer Contract and Host Configuration Boundary

| Layer | ID | Description |
|-------|----|-------------|
| URS   | Via FS | Platform-native realization, thin host configuration |
| FS    | FS-310 | Renderer Policy Boundary — materialize explicit canonical policy, no local allow rules |
| FS    | FS-161 / FS-162 | Canonical realization authority and peer-renderer boundary |
| FS    | FS-168 / FS-169 | Renderer consumption and rendered-output coverage |
| FS    | FS-320 | Renderer Layout Preservation — compact layouts preserve roles/policy/hygiene |
| FS    | FS-770 | Common Intent For Containerlab/Linux And NixOS — same modeled meaning for both lab profiles |
| FS    | FS-780 | Containerlab/Linux And NixOS Equivalence Matrix — compare scope, policy, reachability, address authority, NAT, public ingress, routing, DNS, discovery, service exposure |
| FS    | FS-982 | Host Configuration Renderer Boundary — NixOS and Containerlab/Linux host config stays thin; generated network realization belongs in renderers, not host profiles |

### Public Ingress Runtime Destination

`FS-230-HDS-010-SDS-010-SMS-040` owns protected IPv6 public-ingress
materialization. CLAB preserves the same canonical tuple as NixOS, mounts only the
opaque protected prefix source, derives the tenant `/64` and exact endpoint
`/128` inside the runtime, and emits the exact family/protocol/port/interface
rule with stateful return and no NAT66. Missing, malformed, or ambiguous
runtime input fails closed; family-neutral rules are never expanded into IPv6.

### Pipeline

```
network-labs → compiler → NFM → CPM → realization → schema validation → CLAB renderer
```

### Owning Repository

Construction tests: `network-renderer-containerlab-linux-backend/tests/`

## Contract

- Upstream network meaning reaches this renderer only through the validated
  canonical bundle.
- The optional platform-binding bundle supplies bounded CLAB mechanics and may
  not create network meaning.
- This renderer emits Containerlab/Linux backend
  files.
- Missing, partial, or inconsistent input must fail evaluation.
- Renderer output must be deterministic for the same bundle and binding identities.

## VLAN Boundary

Do not use `vlan2` as testing infrastructure.

`vlan2` is the runtime management/reachability network for the VM/host
lifecycle. It must stay separate from Containerlab test semantics, generated
test uplinks, fake-provider paths, or mini POC traffic. If a test needs DHCP
uplinks, use `vlan4` or `vlan5` and make that canonical or validated
platform-binding input explicit.

## Allowed

- Render Containerlab topology files from explicit realized nodes, links,
  interfaces, services, and host bridge attachments.
- Emit helper artifacts required to start the generated lab backend.
- Preserve canonical routing mode and service data without reinterpretation.
- Accept harness-scoped fake-provider or PPPoE-like lab-emulation artifacts
  only when the request carries explicit lab-emulation capability facts.

## Not Allowed

- This renderer must not invent topology, forwarding, policy, overlay, tenant,
  or routing meaning.
- Choose static vs BGP or any other control-plane mode locally.
- Guess missing bridge/link/interface semantics from names.
- Implement provider-specific overlay runtime such as Nebula, WireGuard, or
  OpenVPN unless the canonical bundle explicitly carries that selected target
  behavior.
- Infer fake-provider or PPPoE-like emulation from interface names, VLAN IDs,
  host names, or provider-like labels.
- Consume CPM side-channel fields such as `upstreamEmulation` or
  `providerAccess`.

## Controlled API

Current controlled consumers use:

```nix
inputs.network-renderer-containerlab-linux-backend.lib.renderer.canonical.hostModule {
  inherit bundle platformBinding;
  hostName = "s-router-clab";
}
```

`validateInput` under the same `renderer.canonical` namespace exposes the
common bundle, scope, target, and optional binding validation result.

## Superseded direct-CPM CLI

The following commands remain for historical direct-entry regression fixtures.
They are not the controlled canonical boundary and cannot produce current
FS-166 evidence by themselves.

```bash
nix run .#generate-clab-config -- \
  ./output-control-plane-model.json \
  ./fabric.clab.yml \
  ./vm-bridges-generated.nix
```

Deploy from explicit CPM and renderer inventory JSON:

```bash
nix run .#deploy-clab -- \
  --work-dir /var/lib/network-renderer-containerlab-linux-backend \
  ./output-control-plane-model.json \
  ./renderer-inventory.json
```

`deploy-clab` does not parse intent or inventory Nix
files; callers must build the CPM JSON first and pass renderer inventory as
JSON. The command renders `fabric.clab.yml` and `vm-bridges-generated.nix`,
evaluates the rendered bridge artifact, prepares the Docker tooling image
cache, clears stale Containerlab state for the rendered lab, materializes host
bridges and explicit VLAN/NAT bridge attachments, deploys Containerlab, and
checks that rendered fabric containers have non-loopback interfaces.

For historical diagnostic use, pin this flake and invoke the superseded app
with locked CPM and renderer-inventory artifacts. `--dry-run` renders artifacts
and the bridge plan without touching Docker, Linux links, or Containerlab, but
does not turn that direct-entry path into the controlled renderer boundary.

## Tests

Run:

```bash
./tests/test.sh
```
