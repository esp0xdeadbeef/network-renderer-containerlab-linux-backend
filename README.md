
# Disclaimer

This project exists primarily to support my own infrastructure.

If it happens to be useful to others, great - just make sure to pin
a specific version (see the Nix manual for how to do this).

If it does not fit your needs, feel free to fork it and adapt it.
Pull requests are welcome, but they are unlikely to be merged if they
conflict with the architectural model used here.

The internal model and schema may change between versions.
Backward compatibility is not guaranteed.


# Control-plane model → Containerlab renderer

This project generates a Containerlab topology (and a small Nix snippet for VM bridge setup) from an explicit **control-plane model** JSON.

Pipeline:

intent + inventory
  -> compiler
  -> forwarding model
  -> control-plane model
  -> this renderer


## Repositories

If you want to develop locally, you can clone these repos side-by-side (optional):

```bash
git clone https://github.com/esp0xdeadbeef/network-compiler
git clone https://github.com/esp0xdeadbeef/network-forwarding-model
git clone https://github.com/esp0xdeadbeef/network-control-plane-model
git clone https://github.com/esp0xdeadbeef/network-renderer-containerlab-linux-backend
git clone https://github.com/esp0xdeadbeef/network-labs
```

For reproducible testing and a stable backlog of inputs, prefer the flake-locked tests in this repo
instead of referencing sibling checkouts.


## Requirements

Nix with flakes enabled.


## Step 1 — Build a control-plane model JSON

From a lab `intent.nix` + `inventory.nix` (using the flake-locked `network-labs` input):

```bash
repo_root="$(pwd)"

# Resolve the pinned flake inputs from *this repo's* flake.lock.
resolve_input_path() {
  local name="$1"
  local archive_json
  archive_json="$(mktemp)"
  nix flake archive --json "path:${repo_root}" > "${archive_json}"
  INPUT_NAME="${name}" ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      name = builtins.getEnv "INPUT_NAME";
      input = archived.inputs.${name} or null;
      p = if input == null then null else input.path or null;
    in
      if p == null then throw "missing archived input path for " + name else p
  '
  rm -f "${archive_json}"
}

labs_path="$(resolve_input_path network-labs)"
cpm_path="$(resolve_input_path network-control-plane-model)"

nix run "${cpm_path}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/single-wan/intent.nix" \
  "${labs_path}/examples/single-wan/inventory.nix" \
  "${repo_root}/output-control-plane-model.json"
```

## Step 2 — Render Containerlab topology

```bash
nix run github:esp0xdeadbeef/network-renderer-containerlab-linux-backend#generate-clab-config -- \
  ./output-control-plane-model.json \
  ./fabric.clab.yml \
  ./vm-bridges-generated.nix
```

This generates:

fabric.clab.yml
vm-bridges-generated.nix


## Step 3 — Start VM

```bash
./start-vm.sh
```

Connect to the VM:

```bash
ssh -o "StrictHostKeyChecking no" -p2222 root@localhost
```


## Notes

Routing / control-plane behavior is owned by upstream stages (forwarding model + inventory + control-plane model).

This renderer should be a pure consumer of the control-plane model JSON: it should not “choose a mode” (static vs BGP, etc).

Routing mode is driven from explicit control-plane-model input (`runtimeTargets.*.routingMode` and optional `runtimeTargets.*.bgp`),
not from renderer environment variables.

Router roles:

core  
policy  
access  
upstream-selector

## Required CPM contract

This renderer should consume one canonical control-plane shape from upstream.

In practice it expects explicit CPM data for:

- runtime targets and routing mode
- realized nodes and links
- service exposure intent
- site overlay projections
- host bridge / attach realization

If upstream data is incomplete, the correct direction is to fix the upstream stage or the example inventory,
not to invent missing semantics in this renderer.

## Overlay scope

This backend renders overlay-related network topology and policy consumption from CPM.

It does not yet claim to be a full Nebula runtime provisioner.

That means:

- overlay termination and overlay-facing topology should render correctly
- full overlay daemon/bootstrap material may still belong to a different layer or a future extension

## Tests (flake-locked)

This repository includes a flake-locked smoke test that:

- builds CPM JSONs from the pinned `network-labs` examples
- runs this renderer against each example
- asserts the renderer produces basic expected artifacts

Run:

```bash
./tests/test.sh
```
