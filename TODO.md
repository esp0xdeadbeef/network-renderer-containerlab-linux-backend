# TODO

## Firewall / Policy Enforcement

- Implement policy enforcement using **nftables**
- Generate nft rules from **solver policy output**
- Run firewall only on the **policy router (s-router-policy)**

## Renderer Tasks

- Parse `policy.rules` from solver output
- Resolve tenant names → tenant subnets
- Resolve service capabilities → ports
- Resolve `external` references → uplinks
- Generate nftables ruleset
- Preserve rule **priority / ordering**

## Runtime Integration

- Write nftables files to `output/nftables/`
- Mount directory into containers
- Load rules on container startup

## Interface Tagging / Isolation

- Use **interface tagging** wherever possible
- Use **fwmarks for internal traffic classification**
- Mask physical interface names so rules do not depend on `ethX`
- Exception: **upstream-selector cannot use interface tagging**

## Forwarding Restrictions

- Disable forwarding on **eth0 (containerlab management interface)** by default
- Only allow forwarding on eth0 for:
  - `clab-fabric-esp0xdeadbeef-site-a-wan-peer-wan` (fake ISP)

## Rule Model

- Default policy: **drop**
- Allow rules generated from solver
- Deny rules generated from solver
- Support IPv4 and IPv6

## Validation

- client → mgmt DNS **blocked**
- admin → mgmt DNS **allowed**
- client → mgmt **blocked**
- client → WAN **allowed**
