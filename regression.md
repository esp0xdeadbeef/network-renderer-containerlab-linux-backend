# network-renderer-containerlab-linux-backend regression

Current verified state as of 2026-05-13.

## architecture shape

- state=required | target=s88-style Enterprise/Site/Unit/EquipmentModule/ControlModule layout | reason=renderer code must stay in s88-style responsibility folders; top-level files are limited to flakes, tests, scripts/entrypoints, and thin imports into the renderer structure.
- state=required | target=no oversized implementation files | reason=Nix implementation files over 200 LOC must be split by concrete renderer responsibility unless they are flake/test wiring or explicitly documented as a temporary regression with a split target.

## fixed and locally verified

- state=fixed-but-only-locally-tested | target=policy interface lane tagging | evidence=`bash tests/test-policy-interface-tags-no-generated-link-parsing.sh` and `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-passing-fixtures.sh` passed for all locked `network-labs` examples | reason=Network pipeline contract audit found CLAB policy interface tags parsed generated p2p link names (`--access-` / `--uplink-`). The renderer now carries explicit CPM/NFM link lane metadata into `LinkModel` and tags policy interfaces from that structured metadata instead of generated names.
- state=fixed-but-only-locally-tested | target=CPM policy endpoint preservation | evidence=`NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-passing-fixtures.sh` passed for all locked `network-labs` examples | reason=Network pipeline contract audit found CLAB loaded only `communicationContract` into the site policy view, so explicit CPM `policy.endpointBindings.externals` were invisible and declared externals such as `isp-a`/`isp-b` failed validation. The renderer now preserves endpoint bindings from CPM input instead of inferring declarations from `domains.externals`.
- state=fixed-but-only-locally-tested | target=CPM backingRef lane/uplink preservation | evidence=`NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-passing-fixtures.sh` passed for all locked `network-labs` examples, including `single-wan-direct-transit` | reason=Network pipeline contract audit found CLAB dropped explicit `effectiveRuntimeRealization.interfaces.*.backingRef.lane` metadata for direct links, causing policy interface tagging to collapse tenant/uplink lanes to generic `wan`. The renderer now carries backingRef lane/uplink/overlay metadata into the intermediate link model for both bridged and direct interfaces.
- state=fixed-but-only-locally-tested | target=access tenant resolution | evidence=`bash tests/test-access-tenant-no-node-name-parsing.sh` | reason=Network pipeline contract audit found CLAB access tenant resolution could tokenize runtime node names. The renderer now requires explicit tenant interface metadata or a single unambiguous modeled tenant candidate.
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
- Containerlab DNS services now preserve explicit CPM
  `services.dns.outgoingInterfaces` by binding the runtime DNS proxy's upstream
  sockets to modeled source addresses before forwarding queries. Focused
  regression passed:
  `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-dns-service-source-binding.sh`.
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
- state=still-broken | target=current s-router-clab live lab | evidence=2026-05-13 s-router-clab host was reachable and IPv4 default via vlan2 worked, host IPv6 route lookup for 2606:4700:4700::1111 failed with network unreachable, and host-level `docker ps -a` / `containerlab inspect --all` did not show a fabric; the nested `s-router-clab-container` still had 26 `clab-fabric-*` containers running from an older deploy | reason=current CLAB box has a stale nested fabric, but the current host render/deploy path is not green.
- state=still-broken | target=fast current s-router-clab refresh | evidence=2026-05-13 fast matrix `/tmp/s-router-fast-enum-20260513T212251Z/summary/fast.tsv` captured 28 CLAB rows: the host and nested container public IPv4 classify as home-WAN management egress, while every `clab-fabric-*` container has no public IPv4 route and DNS returns network unreachable. | reason=CLAB is currently not a valid data-plane validation surface; the renderer deploy path must first stop crashing and recreate a usable fabric.
- state=still-broken | target=nested s-router-clab fabric egress | evidence=2026-05-13 all 26 nested `clab-fabric-*` containers returned zero global IPv4 addresses, zero global IPv6 addresses, and `RTNETLINK answers: Network unreachable` for route lookup to 1.1.1.1 and 2606:4700:4700::1111; compact evidence is in `/tmp/s-router-clab-docker-compact.tsv` on the operator box. | reason=even the currently running nested fabric is not a usable public-egress or route-policy validation target.
- state=still-broken | target=s-router-clab-render-live.service | evidence=2026-05-13 service failed with FileNotFoundError for `git` in clabgen/parse-solver-json.py `_git_dirty`, while running from the Nix store generated renderer path | reason=renderer helper metadata collection assumes `git` exists at runtime; this blocks CLAB fabric deployment before any container data-plane validation can start.
- state=fixed-but-only-locally-tested | target=s-router-clab-render-live missing `git` failure | evidence=2026-05-13 local focused regression `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-provenance-without-git.sh` passed after `_git_dirty` was changed to treat missing `git` as dirty provenance instead of crashing. | reason=The fix has not yet been pushed, locked downstream, or consumed by a live `s-router-clab` deploy.
- state=still-broken | target=CLAB host leak posture | evidence=2026-05-13 compact probe classified `s-router-clab` host public IPv4 as `HOME_LEAK`, host IPv6 public route as unreachable, DNS resolvers on vlan2 included the LAN resolver plus public resolvers, and host nft forward hooks had policy accept with NAT masquerade toward vlan2. | reason=Host realization currently exposes the operator/home WAN path; this may be expected for host management but must not be mistaken for validated CLAB fabric egress and must not leak concrete home IPv4 into source.

## previous live validation

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
