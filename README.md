# Network Compiler → Solver → Containerlab Renderer

This project generates a Containerlab network topology from a high level
network model.

Pipeline:

network-compiler -> network-solver -> renderer


## Repositories

Clone the required repositories:

git clone https://github.com/esp0xdeadbeef/network-compiler
git clone https://github.com/esp0xdeadbeef/network-solver
git clone https://github.com/esp0xdeadbeef/network-renderer-containerlab-linux-backend


## Requirements

Nix with flakes enabled.


## Step 1 — Compile

cd network-compiler

nix run .#compile -- examples/multi-wan/inputs.nix

This produces:

output-compiler-signed.json


## Step 2 — Solve

cd ../network-solver

nix run .#compile-and-solve -- ../network-compiler/examples/multi-wan/inputs.nix

This produces:

output-solver-signed.json


## Step 3 — Render Containerlab topology

cd ../network-renderer-containerlab-linux-backend

./run-clab-generator.sh

This generates:

fabric.clab.yml
vm-bridges-generated.nix


## Step 4 — Start VM

./start-vm.sh

Connect to the VM:

ssh -o "StrictHostKeyChecking no" -p2222 root@localhost


## Notes

Current routing: static routes

Router roles:

core  
policy  
access  
upstream-selector
