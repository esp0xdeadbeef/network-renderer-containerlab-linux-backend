
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

If you want to develop locally, clone these repos side-by-side (optional):

```bash
git clone https://github.com/esp0xdeadbeef/network-compiler
git clone https://github.com/esp0xdeadbeef/network-forwarding-model
git clone https://github.com/esp0xdeadbeef/network-control-plane-model
git clone https://github.com/esp0xdeadbeef/network-renderer-containerlab-linux-backend
git clone https://github.com/esp0xdeadbeef/network-labs
```


## Requirements

Nix with flakes enabled.


## Step 1 — Build a control-plane model JSON

From a lab `intent.nix` + `inventory.nix` (for example from `network-labs/examples/...`):

```bash
OUT_DIR="$(pwd)"
LABS_DIR="$(cd ../network-labs && pwd)"
nix run github:esp0xdeadbeef/network-control-plane-model#compile-and-build-control-plane-model -- \
  "$LABS_DIR/examples/single-wan/intent.nix" \
  "$LABS_DIR/examples/single-wan/inventory.nix" \
  "$OUT_DIR/output-control-plane-model.json"
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
