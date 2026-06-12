"""Shared WAN index counter for deterministic IP assignment.

This counter persists across render() calls. It was previously used for
static IP and SNAT assignment from the VLAN4 pool; after the switch to
DHCP for WAN interfaces (FS-380-HDS-010-SDS-010-SMS-060-CMC), only
reset_wan_index() is used by topology.py to reset the counter between
topology renders.
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
