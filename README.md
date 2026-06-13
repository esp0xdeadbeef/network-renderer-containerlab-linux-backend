# network-renderer-containerlab-linux-backend

`network-renderer-containerlab-linux-backend` emits Containerlab/Linux backend
artifacts from explicit `network-control-plane-model` output.

It is an emission stage only.

Pipeline position: this repository is downstream of
`network-control-plane-model` and upstream of Containerlab/Linux backend
artifacts.

Migration, deviation, exception, transition, or temporary compatibility behavior
must be explicit in the README, tests, and owning layer before it is accepted.

```text
network-forwarding-model -> network-control-plane-model -> network-renderer-containerlab-linux-backend
```

## Spec Chain

This renderer materializes Containerlab/Linux backend artifacts from explicit CPM output.
All behavior requirements originate from the FS spec chain.

### Owning Chain: Renderer Contract and Host Configuration Boundary

| Layer | ID | Description |
|-------|----|-------------|
| URS   | Via FS | Platform-native realization, thin host configuration |
| FS    | FS-310 | Renderer Policy Boundary — materialize explicit CPM policy, no local allow rules |
| FS    | FS-320 | Renderer Layout Preservation — compact layouts preserve roles/policy/hygiene |
| FS    | FS-770 | Common Intent For Containerlab/Linux And NixOS — same modeled meaning for both lab profiles |
| FS    | FS-780 | Containerlab/Linux And NixOS Equivalence Matrix — compare scope, policy, reachability, address authority, NAT, public ingress, routing, DNS, discovery, service exposure |
| FS    | FS-982 | Host Configuration Renderer Boundary — NixOS and Containerlab/Linux host config stays thin; generated network realization belongs in renderers, not host profiles |

### Pipeline

```
network-labs (intent + inventory) → network-compiler → NFM → CPM → network-renderer-containerlab-linux-backend
```

### Owning Repository

Construction tests: `network-renderer-containerlab-linux-backend/tests/`

## Contract

- The forwarding model and CPM are the source of truth.
- This renderer consumes resolved CPM data and emits Containerlab/Linux backend
  files.
- Missing, partial, or inconsistent input must fail evaluation.
- Renderer output must be deterministic for the same CPM input.

## Allowed

- Render Containerlab topology files from explicit realized nodes, links,
  interfaces, services, and host bridge attachments.
- Emit helper artifacts required to start the generated lab backend.
- Preserve CPM routing mode and service data without reinterpretation.
- Accept harness-scoped fake-provider or PPPoE-like lab-emulation artifacts
  only when the request carries explicit lab-emulation capability facts.

## Not Allowed

- This renderer must not invent topology, forwarding, policy, overlay, tenant,
  or routing meaning.
- Choose static vs BGP or any other control-plane mode locally.
- Guess missing bridge/link/interface semantics from names.
- Implement provider-specific overlay runtime such as Nebula, WireGuard, or
  OpenVPN unless CPM explicitly models that backend output for this renderer.
- Infer fake-provider or PPPoE-like emulation from interface names, VLAN IDs,
  host names, or provider-like labels.
- Consume CPM side-channel fields such as `upstreamEmulation` or
  `providerAccess`.

## Usage

Build CPM JSON from a pinned lab example, then render:

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

`deploy-clab` is downstream of CPM. It does not parse intent or inventory Nix
files; callers must build the CPM JSON first and pass renderer inventory as
JSON. The command renders `fabric.clab.yml` and `vm-bridges-generated.nix`,
evaluates the rendered bridge artifact, prepares the Docker tooling image
cache, clears stale Containerlab state for the rendered lab, materializes host
bridges and explicit VLAN/NAT bridge attachments, deploys Containerlab, and
checks that rendered fabric containers have non-loopback interfaces.

For deterministic service integration, pin this flake and invoke the app with
locked CPM and renderer-inventory artifacts. `--dry-run` renders artifacts and
the bridge plan without touching Docker, Linux links, or Containerlab.

## Tests

Run:

```bash
./tests/test.sh
```
