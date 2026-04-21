# Implementation Plan

Goal: make the containerlab backend a pure S88 renderer that consumes CPM as-is, instead of compensating for upstream shape drift with local solver logic.

## Current S88 posture

The README says the right thing:

- this repo is a control-plane-model consumer
- routing mode comes from CPM
- the renderer should not choose topology meaning

The code is close, but current compatibility shims show that the CPM contract is not yet treated as fully authoritative end-to-end.

## Main gaps

1. Overlay handling still contains compatibility behavior.
   - Recent fixes had to preserve overlay identity and inject `site.overlays` into transport views locally.
   - That means the renderer is still normalizing upstream semantics instead of only rendering them.

2. Firewall/context derivation still tolerates multiple upstream shapes.
   - Accepting alternate `terminateOn` forms and relaxed `mustTraverse` semantics is useful short term, but it weakens the idea of one S88 contract.

3. README understates the actual required CPM fields.
   - The boundary should explicitly list what this renderer consumes.

4. Overlay runtime provisioning is only partially in scope.
   - The renderer now understands overlay termination semantics, but does not fully render Nebula runtime artifacts.
   - That scope boundary should be explicit.

## Work items

1. Remove renderer-local semantic normalization over time.
   - Make `solver.py`, `site_loader.py`, and firewall context consume one canonical CPM shape.
   - Keep compatibility code only behind clearly temporary adapters, then delete it.

2. Document the required CPM contract in `README.md`.
   - Include:
     - runtime targets
     - node/link identity
     - overlay projections
     - service exposure data
     - routing mode data
     - host bridge requirements

3. Decide and document overlay scope.
   - Either:
     - emit full Nebula/container runtime inputs, or
     - explicitly state that overlay daemon provisioning is out of scope and only network topology is rendered.

4. Add contract-focused renderer tests.
   - Keep flake-locked sweeps.
   - Keep sibling-local regression for in-flight examples.
   - Add one CPM-only test for overlay + service + multi-uplink consumption.

5. Tighten failure behavior.
   - Where canonical CPM fields are missing, fail instead of silently adapting.

## Exit criteria

- The renderer consumes one documented CPM shape.
- Overlay support works without local semantic repair.
- The README accurately describes both what is rendered and what is intentionally out of scope.
- Tests cover both pinned examples and one explicit S88 overlay regression.

## Test impact

- Keep `tests/test.sh` as the broad gate.
- Keep the dedicated dual-site overlay regression.
- Add one test that fails on missing canonical overlay fields instead of accepting alternate shapes forever.
