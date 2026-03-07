# TODO — Routing Simplification (Renderer)

Goal:
Stop installing unnecessary fabric /31 routes everywhere. Only install routes that a node actually needs to forward traffic.

Current problem:
Access, policy, upstream-selector, and core routers receive routes for every P2P fabric link.

Example currently rendered:

10.10.0.0/31
10.10.0.2/31
10.10.0.4/31
10.10.0.6/31
10.10.0.8/31
10.10.0.10/31

These are link networks and should normally only exist as connected routes on the routers that terminate them.

Routers that do not terminate the link should never receive these routes.


--------------------------------

1. Access routers

Access routers should be extremely simple.

They should only have:

connected:
  p2p link to policy
  tenant subnet(s)

static:
  default → policy router

Example desired state:

connected:
  10.10.0.0/31 dev eth1
  10.20.x.0/24 dev eth2

static:
  default via 10.10.0.1


Do NOT install routes for:

10.10.0.2/31
10.10.0.4/31
10.10.0.6/31
10.10.0.8/31
10.10.0.10/31


--------------------------------

2. Policy router

Policy routers sit between access and upstream-selector.

They should know:

connected:
  all access links
  upstream-selector link

static:
  tenant prefixes via access routers
  default via upstream-selector


Example:

connected:
  10.10.0.0/31
  10.10.0.2/31
  10.10.0.4/31
  10.10.0.10/31

static:
  10.20.10.0/24 via access-mgmt
  10.20.15.0/24 via access-admin
  10.20.20.0/24 via access-client
  default via upstream-selector


Do NOT install routes for core fabric links.


--------------------------------

3. Upstream-selector

Upstream-selector should know:

connected:
  policy link
  links to all cores

static:
  tenant prefixes via policy


Example:

connected:
  10.10.0.10/31
  10.10.0.6/31
  10.10.0.8/31

static:
  10.20.10.0/24 via policy
  10.20.15.0/24 via policy
  10.20.20.0/24 via policy


Do NOT install access link networks.


--------------------------------

4. Core routers

Core routers should know:

connected:
  link to upstream-selector
  link to WAN

static:
  tenant prefixes via upstream-selector
  default via WAN peer


Example:

connected:
  10.10.0.6/31
  10.19.0.0/31

static:
  10.20.10.0/24 via upstream-selector
  10.20.15.0/24 via upstream-selector
  10.20.20.0/24 via upstream-selector
  default via 10.19.0.1


Do NOT install access or policy fabric link routes.


--------------------------------

5. Renderer algorithm change

Instead of exporting all solver routes to every router:

The renderer must compute the minimal routing view for each node.

Algorithm outline:

For each node:
  include all connected interfaces
  include routes for owned tenant prefixes
  include routes required for next-hop forwarding
  include default routes where defined

Exclude:
  routes for links the node is not directly connected to


--------------------------------

6. Duplicate route elimination

The renderer currently emits duplicate commands such as:

ip route replace 10.10.0.10/31 via 10.10.0.1
ip route replace 10.10.0.10/31 via 10.10.0.1

Ensure route list is deduplicated before rendering.


--------------------------------

7. Skip connected routes

Renderer should not emit routes for networks already installed by the kernel.

Example to skip:

ip route replace 10.10.0.0/31 dev eth1 scope link


These appear automatically when assigning addresses.


--------------------------------

Expected result:

Routing tables become much smaller and clearer.

Access routers:
  ~2–3 routes

Policy routers:
  ~5–6 routes

Upstream-selector:
  ~4–5 routes

Core routers:
  ~4–5 routes
