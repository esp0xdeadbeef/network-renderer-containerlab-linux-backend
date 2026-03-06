# TODO: Normalize CIDR prefixes before rendering routes

## Problem

The solver may emit destination prefixes that are **not canonical network addresses** (e.g. `/31` host-form prefixes like `10.10.0.3/31`). While these are logically valid CIDR representations, the Linux routing stack (`ip route`) **requires canonical network prefixes**.

Example solver output:

```
dst: 10.10.0.3/31
via: 10.10.0.5
```

Linux rejects this:

```
ip route replace 10.10.0.3/31 via 10.10.0.5
Error: Invalid prefix for given prefix length
```

because `/31` networks must be rendered with the **network base address**.

Canonical equivalent:

```
10.10.0.2/31
```

---

## Required Renderer Fix

Before emitting any route, **normalize the CIDR prefix to its canonical network address**.

Transformation examples:

| Solver output  | Renderer must emit |
| -------------- | ------------------ |
| `10.10.0.1/31` | `10.10.0.0/31`     |
| `10.10.0.3/31` | `10.10.0.2/31`     |
| `10.10.0.5/31` | `10.10.0.4/31`     |

Equivalent rule:

```
dst = network(dst)
```

---

## Implementation Strategy

For every route:

1. Parse CIDR prefix
2. Compute network address
3. Emit normalized CIDR

Pseudo:

```
ip, mask = parseCIDR(dst)
network = ip & mask
dst = formatCIDR(network, mask)
```

---

## Scope

Normalization must be applied to:

* `routes.ipv4[].dst`
* `routes.ipv6[].dst`

Before generating any:

```
ip route replace ...
ip -6 route replace ...
```

---

## Acceptance Criteria

Renderer must transform solver output such that commands like:

```
ip route replace 10.10.0.3/31 via 10.10.0.5
```

are rendered as:

```
ip route replace 10.10.0.2/31 via 10.10.0.5
```

and no longer produce:

```
Error: Invalid prefix for given prefix length
```

during containerlab execution.

