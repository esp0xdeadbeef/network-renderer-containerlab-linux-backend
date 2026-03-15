TODO — Solver/Renderer: Implement correct internal BGP topology

Problem
The current generated BGP configuration does not form a working routing control plane.

Observed issues:
- No BGP neighbor statements are generated, so no sessions are formed.
- Each router uses a different ASN, preventing an iBGP topology.
- Transport networks (/31, /127 p2p links) are incorrectly advertised via BGP.
- Duplicate address-family blocks are generated in FRR configs.
- Client nodes run FRR/BGP even though they should behave as simple hosts.
- Some router-ids use network addresses instead of stable loopbacks.
- The solver does not define a BGP topology, forcing the renderer to guess.

Required behavior
- All internal routers share a single site ASN.
- The solver defines the internal BGP topology explicitly.
- BGP sessions use loopback addresses as router-id and update-source.
- Only service prefixes and loopbacks are advertised via BGP.
- Transport link networks remain local and are not exported.
- Client nodes must not run BGP.

Recommended model
Use a route-reflector topology:

access routers -> policy router (RR)
core router -> policy router (RR)
upstream selector -> policy router (RR)

Goal
The solver emits a deterministic BGP topology model and the renderer translates it into valid FRR configuration that forms established BGP sessions.
