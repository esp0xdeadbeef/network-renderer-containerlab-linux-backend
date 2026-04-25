# network-renderer-containerlab-linux-backend regression

Current verified state as of 2026-04-24.

## fixed and live-verified

- `start-vm.sh` boots a fresh VM from the current repo state, and SSH on the chosen forwarded port works.
- `run-in-vm.sh` now succeeds on that fresh VM and `containerlab deploy -t fabric.clab.yml -d --reconfigure` completes without the previous duplicate-endpoint failure in the validated `single-wan` path.
- `containerlab inspect -t fabric.clab.yml` shows all rendered `single-wan` nodes running inside the VM.
- The rendered `single-wan` client path is live-verified in the VM:
  - `client-s-router-access-mgmt-tenant-mgmt` reaches `10.20.10.1`
  - `ip route get 8.8.8.8` uses `via 10.20.10.1 dev eth1`
  - `ping -c1 8.8.8.8` succeeds

## fixed but only locally tested

- The renderer no longer duplicates single-ended host bridge links. Root cause was `render_units()` appending the same link twice after mutating a 1-endpoint link into a 2-endpoint link.
- `tests/validate-topology-conformance.sh` now fails if the rendered YAML contains duplicate endpoint pairs.
- `bash tests/test.sh` passes on the current repo state.
- Re-rendering the exact `start-vm.sh` `single-wan` path no longer produces duplicate links in `fabric.clab.yml`.
- The tmux matrix workers now allocate per-worker VM state under `${XDG_CACHE_HOME:-$HOME/.cache}/network-renderer-containerlab-linux-backend/clab-vm-matrix` instead of `/tmp`, so worker qcow state is no longer created under `/tmp/clab-vm-*`.
- `tests/test-vm-examples.sh` now writes per-example launcher logs and CPM scratch dirs under the worker/state cache root instead of `/tmp`.
- `docker-clab-frr-plus-tooling/build.sh` now supports a staged cache tar via `CLAB_FRR_TOOLING_CACHE_TAR` and `CLAB_FRR_TOOLING_CACHE_IMAGE_ID_FILE`, so the VM can `docker load` the host-exported tooling image instead of rebuilding it every time.

## implemented but not yet live-validated

- Host-side export/import caching for `clab-frr-plus-tooling:latest` is wired through `tests/test-vm-examples.sh`, but I still do not have a full successful live run of that host-export -> scp -> VM import path.

## still broken

- The tmux VM-example matrix currently fails in this shell when it tries to build/export the FRR tooling cache from the host:
  - `permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock`
  - the follow-on export step then fails because the temporary tar was never created:
    - `mv: cannot stat '...clab-frr-plus-tooling-latest.tar.tmp': No such file or directory`
- Because of that Docker-daemon permission failure, the new host-side image cache path is not usable yet from the tmux matrix in the current environment.
- The worker panes still emit terminal-noise lines from the guest shell environment:
  - `resize: can't open terminal /dev/tty`
  - `resize: Terminal is not VT100-compatible`
- The tmux VM-example matrix also currently fails on `single-wan-vlan-trunk-lanes`:
  - `start-vm.sh` tries to fetch the flake input from `path:/home/deadbeef/github/network-renderer-containerlab-linux-backend`
  - that fetch fails because it expects a repo-local `clab-fabric` path that does not exist:
    - `error: path '//home/deadbeef/github/network-renderer-containerlab-linux-backend/clab-fabric' does not exist`
  - the follow-on archived-input lookup then parses empty JSON and reports missing example inputs:
    - `intent: /examples/single-wan-vlan-trunk-lanes/intent.nix`
    - `inventory: /examples/single-wan-vlan-trunk-lanes/inventory-clab.nix`
- The same `single-wan-vlan-trunk-lanes` failure is reproducible from the tmux worker path itself, not just from a one-off shell run:
  - worker output shows:
    - `[vm-test] compiling CPM for single-wan-vlan-trunk-lanes`
    - `[vm-test] starting VM for single-wan-vlan-trunk-lanes`
    - `ssh -o 'StrictHostKeyChecking no' -p2224 root@localhost # to connect to the vm.`
  - then the VM launcher fails before example input resolution completes:
    - `error: path '//home/deadbeef/github/network-renderer-containerlab-linux-backend/clab-fabric' does not exist`
    - `error: [json.exception.parse_error.101] parse error at line 1, column 1: attempting to parse an empty input`
  - and the example-specific inputs are still reported as missing:
    - `intent: /examples/single-wan-vlan-trunk-lanes/intent.nix`
    - `inventory: /examples/single-wan-vlan-trunk-lanes/inventory-clab.nix`

## pending or unknown

- I did not boot a separate VM for every example to successful completion yet. The broader matrix harness is still blocked by the host Docker-daemon/cache failure above.
- I did not perform an `s-router-test`-style hostile/DNS-leak validation campaign inside containerlab. Current live validation here is topology/render/deploy/runtime reachability, not full security-policy parity with the NixOS lab.
- `run-in-vm.sh` is still a coarse dump-and-probe script. It proves deployability and basic routed behavior, but it is not yet a structured assertion suite.

## next concrete debugging target

- Make the tmux VM-example matrix robust in this environment:
  - either provide a non-Docker host cache path for `clab-frr-plus-tooling:latest`
  - or make the matrix detect missing host Docker-daemon access and skip the host-export path cleanly instead of cascading into a missing-tar failure
- Fix `start-vm.sh` / `test-vm-examples.sh` path handling for archived local flake inputs so examples like `single-wan-vlan-trunk-lanes` do not resolve repo-relative `clab-fabric` paths as missing absolute paths.
- After that, rerun the matrix and confirm that multiple examples boot, deploy, validate, and shut down cleanly without leaving qcow state under `/tmp`.
