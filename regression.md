# network-renderer-containerlab-linux-backend regression

Current verified state as of 2026-05-03.

## fixed and locally verified

- The pinned fixture sweep passes with warning output treated as a failure:
  `./tests/test-passing-fixtures.sh`.
- The sweep includes `s-router-test-three-site` and both tri-site overlay
  integration examples.
- NixOS-renderer-style focused regressions were copied/adapted for this backend
  and now render `s-router-test-three-site` from `inventory-clab.nix` before
  asserting the generated Containerlab topology:
  - `tests/test-hostile-dns-east-west.sh`
  - `tests/test-dns-service-policy-routes.sh`
  - `tests/test-hostile-gua-advertisements.sh`
  - `tests/test-s-router-clab-overlay-parity.sh`
- Those focused tests passed locally as a batch:
  `./tests/test-hostile-dns-east-west.sh &&
  ./tests/test-dns-service-policy-routes.sh &&
  ./tests/test-hostile-gua-advertisements.sh &&
  ./tests/test-s-router-clab-overlay-parity.sh`.
- Client injection has been removed from the renderer path; clients must come
  from explicit CPM/input data rather than local renderer inference.
- Policy interface tagging now supports multi-tag interfaces and treats missing
  tenant/external mappings as renderer failures instead of warning-only output.
- The `s-router-clab` host is reachable by SSH from this box:
  `ssh s-router-clab id` returned `uid=1000(deadbeef)`.
- The normal repo runner passed after wiring in the copied tests:
  `./tests/test.sh`.
- Service endpoints in firewall policy now follow the NixOS renderer shape:
  service names resolve through explicit `providerTenants`, ownership endpoint
  providers, and the runtime DNS service tenant when the current CLAB fixture
  lacks explicit DNS provider tenants.
- Containerlab runtime nodes now render DNS services from CPM runtime targets.
  The generated DNS process listens on the modeled service addresses, forwards
  to the modeled upstreams/forwarders, and serves modeled local records.
- `s-router-clab` now exposes direct SSH into the nested container on port
  2222. The verified path is:
  `ssh -p 2222 root@s-router-clab`.
- The local FRR tooling image build now has a persistent cache path. On
  `s-router-clab`, `docker-clab-frr-plus-tooling/build.sh` reused the existing
  `clab-frr-plus-tooling:latest` image, seeded
  `/persist/docker-image-cache/network-renderer-containerlab-linux-backend/`,
  and a second run used the cached image without querying Docker Hub.

## live validation

- `s-router-clab` should be used for live Containerlab validation on this box
  because there is no trunk here.
- Like the `s-router-test` workflow, shutting down/restarting `s-router-clab`
  is expected to pick up the latest NixOS config on that box.
- A live `s-router-test-three-site` deploy was run through the direct
  `s-router-clab` container SSH path. The rendered topology was generated on
  the host and copied into the nested container to avoid repeated GitHub/Nix
  input fetches inside the lab box.
- Containerlab created all 28 fabric containers with zero restarts. Data-plane
  links beyond Docker `eth0` were attached, including the overlay links:
  - `esp0xdeadbeef-site-a-s-router-core-nebula:eth4` to
    `espbranch-site-b-b-router-core-nebula:eth3`
  - `esp0xdeadbeef-site-a-s-router-core-nebula:eth5` to
    `esp0xdeadbeef-site-c-c-router-nebula-core:eth3`
- Overlay route probes now resolve through overlay devices instead of Docker
  management:
  - branch core to site-A client:
    `10.20.10.1 via 100.96.10.1 dev eth3`
  - site-A core to branch client:
    `10.60.10.1 via 100.96.10.2 dev eth4`
  - peer overlay host routes:
    `100.96.10.1 dev eth3` and `100.96.10.2 dev eth4`
- Live traffic is green for the overlay and DNS service contracts currently
  checked here:
  - Site-A client to branch access succeeded
    (`10.20.10.1` to `10.60.10.1`).
  - Branch access TCP to site-A DNS connected:
    `10.60.10.1` to `10.20.10.1:53`.
  - Branch access UDP DNS to site-A DNS returned a DNS response from
    `10.20.10.1` with `rcode=2` after the modeled public forwarders timed out
    in the CLAB environment.
- Containerlab `/etc/hosts` cleanup is a NixOS host realization concern, not a
  renderer output issue. `s-router-clab` now carries the same mutable hosts-file
  setting used by older NixOS containerlab hosts; verify it from the live
  `s-router-clab-container` runtime.

## still required

- Keep adding tests similar to `network-renderer-nixos` for any `s-router-test`
  contract that is not yet asserted here. These are required regression tests,
  not optional cleanup.
- The current copied set covers hostile DNS/east-west routes, DNS policy route
  rendering, hostile delegated-GUA absence in Containerlab output, and overlay
  parity nodes/routes. Remaining NixOS renderer contracts still need matching
  Containerlab assertions where they apply.

## next concrete target

- Continue copying applicable `network-renderer-nixos` service/firewall tests
  into this backend, especially around DNS access-control and direct DNS egress
  denial where those contracts apply to Containerlab.
