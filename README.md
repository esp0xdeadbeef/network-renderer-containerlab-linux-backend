# network-renderer-containerlab-linux-backend

`network-renderer-containerlab-linux-backend` emits Containerlab/Linux backend
artifacts from explicit `network-control-plane-model` output.

It is an emission stage only.

```text
network-forwarding-model -> network-control-plane-model -> network-renderer-containerlab-linux-backend
```

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

## Not Allowed

- Invent topology, forwarding, policy, overlay, tenant, or routing meaning.
- Choose static vs BGP or any other control-plane mode locally.
- Guess missing bridge/link/interface semantics from names.
- Implement provider-specific overlay runtime such as Nebula, WireGuard, or
  OpenVPN unless CPM explicitly models that backend output for this renderer.

## Usage

Build CPM JSON from a pinned lab example, then render:

```bash
nix run .#generate-clab-config -- \
  ./output-control-plane-model.json \
  ./fabric.clab.yml \
  ./vm-bridges-generated.nix
```

## Tests

Run:

```bash
./tests/test.sh
```
