"""Shared WAN index counter for deterministic static IP and SNAT assignment.

This counter persists across render() calls so each WAN-enabled container
gets a unique IP from the VLAN4 pool. Both linux_wan_dynamic.py (IP
assignment) and EM/base.py (SNAT IP passthrough) use the same counter.

Only linux_wan_dynamic.py increments the counter (via next_wan_index()).
EM/base.py peeks (via peek_wan_index()) to compute the SNAT IP without
double-incrementing.
"""

_wan_global_index = 0


def next_wan_index() -> int:
    """Return current index and increment."""
    global _wan_global_index
    idx = _wan_global_index
    _wan_global_index += 1
    return idx


def peek_wan_index() -> int:
    """Return current index without incrementing."""
    return _wan_global_index


def reset_wan_index() -> None:
    """Reset counter (for testing)."""
    global _wan_global_index
    _wan_global_index = 0
