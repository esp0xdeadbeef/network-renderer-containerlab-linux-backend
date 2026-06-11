"""
Platform-native nftables primitive registry for the Containerlab/Linux backend.

GAMP-ID: FS-310-HDS-010-SDS-010-SMS-050
Classification: Supplier-owned platform-native primitive registry.

Every entry documents the Containerlab target's standard nftables conventions.
Each primitive must have a documented binding to CPM/provider contracts, target
capability declarations, or this registry. No primitive may be derived from
hostnames, example names, routing assumptions, local scripts, or hardcoded strings.

This registry documents the current baseline of primitives used by CM modules;
it does not change them.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

# ── Registry structure ──────────────────────────────────────────────────────

# Each category is a dict mapping primitive value -> binding metadata.
# Binding metadata includes:
#   source: where the value originates (cpm|target-capability|platform-registry)
#   description: human-readable documentation
#   used_by: list of CM modules that emit this primitive

REGISTRY: Dict[str, Dict[str, Dict[str, Any]]] = {
    "tables": {
        "inet filter": {
            "source": "platform-registry",
            "description": (
                "Standard Containerlab WAN-node filter table. Provides input/forward/output "
                "filter chains for WAN-facing nodes (core, provider nodes). Default firewall "
                "table used when a node has WAN interfaces and no CPM-specific firewall table."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "inet mangle": {
            "source": "platform-registry",
            "description": (
                "WAN-node TCP MSS clamping table. Applies MSS clamping on forward chain "
                "for WAN-facing interfaces at priority mangle (-150). Standard Linux "
                "containerlab convention for WAN path MTU handling."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "inet fw": {
            "source": "platform-registry",
            "description": (
                "CPM-derived policy firewall table. Carries forwarding-intent rules "
                "translated from CPM forwardingIntent.rules entries. Table name 'fw' is a "
                "Containerlab platform convention for the firewall table populated from "
                "explicit CPM policy input."
            ),
            "used_by": ["cpm_firewall_rules.py", "policy_firewall.py"],
        },
        "ip nat": {
            "source": "platform-registry",
            "description": (
                "IPv4 NAT table for masquerade and SNAT. Used by nodes with NAT intent "
                "(core egress nodes). Table family 'ip' is the standard Linux nftables "
                "convention for IPv4-only NAT."
            ),
            "used_by": ["nat.py", "firewall_wan.py"],
        },
        "ip6 nat": {
            "source": "platform-registry",
            "description": (
                "IPv6 NAT table for NAT66/masquerade. Used by nodes with IPv6 NAT intent. "
                "Table family 'ip6' is the standard Linux nftables convention for "
                "IPv6-only NAT."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "inet clab_dns_guard": {
            "source": "platform-registry",
            "description": (
                "DNS public-resolver guard table. Blocks DNS queries to denied public "
                "resolver IP ranges to prevent DNS leak. Table name carries 'clab_' "
                "prefix as a Containerlab-local convention to avoid collision with "
                "system nftables tables."
            ),
            "used_by": ["dns_service.py"],
        },
        "inet clab_guard": {
            "source": "platform-registry",
            "description": (
                "Management egress guard table. Blocks all traffic through eth0 "
                "(management/console interface) on forward and output chains. "
                "Prevents container traffic from leaking through the Containerlab "
                "management plane. Priority -300 ensures it executes before all "
                "other filter chains."
            ),
            "used_by": ["management_egress_guard.py"],
        },
    },
    "chains": {
        "input": {
            "source": "platform-registry",
            "description": (
                "Standard nftables input chain. Used in inet filter for WAN-node inbound "
                "traffic control. Filters traffic entering the node."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "forward": {
            "source": "platform-registry",
            "description": (
                "Standard nftables forward chain. Used in inet filter (WAN forwarding), "
                "inet fw (CPM policy forwarding), inet mangle (MSS clamping), and "
                "inet clab_dns_guard (DNS guard). Filters traffic traversing the node."
            ),
            "used_by": [
                "firewall_wan.py",
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "dns_service.py",
            ],
        },
        "output": {
            "source": "platform-registry",
            "description": (
                "Standard nftables output chain. Used in inet filter for WAN-node outbound "
                "traffic control and inet clab_dns_guard for DNS output leak prevention."
            ),
            "used_by": ["firewall_wan.py", "dns_service.py"],
        },
        "postrouting": {
            "source": "platform-registry",
            "description": (
                "Standard nftables postrouting chain for NAT. Used in ip nat and ip6 nat "
                "tables for masquerade/SNAT on egress interfaces."
            ),
            "used_by": ["nat.py", "firewall_wan.py"],
        },
    },
    "hooks": {
        "filter": {
            "source": "platform-registry",
            "description": (
                "Standard nftables filter hook type. Used for packet filtering chains "
                "(input, forward, output)."
            ),
            "used_by": [
                "firewall_wan.py",
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "dns_service.py",
            ],
        },
        "nat": {
            "source": "platform-registry",
            "description": (
                "Standard nftables nat hook type. Used for address translation chains "
                "(postrouting)."
            ),
            "used_by": ["nat.py", "firewall_wan.py"],
        },
    },
    "hook_types": {
        "input": {
            "source": "platform-registry",
            "description": (
                "Netfilter input hook. Used with filter chains on the input path."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "forward": {
            "source": "platform-registry",
            "description": (
                "Netfilter forward hook. Used with filter chains on the forward path "
                "and with mangle chains for MSS clamping."
            ),
            "used_by": [
                "firewall_wan.py",
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "dns_service.py",
            ],
        },
        "output": {
            "source": "platform-registry",
            "description": (
                "Netfilter output hook. Used with filter chains on the output path."
            ),
            "used_by": ["firewall_wan.py", "dns_service.py"],
        },
        "postrouting": {
            "source": "platform-registry",
            "description": (
                "Netfilter postrouting hook. Used with nat chains for masquerade/SNAT "
                "on the postrouting path."
            ),
            "used_by": ["nat.py", "firewall_wan.py"],
        },
    },
    "families": {
        "ip": {
            "source": "platform-registry",
            "description": (
                "IPv4 address family. Standard Linux nftables family for IPv4-only tables "
                "and rules."
            ),
            "used_by": ["nat.py", "firewall_wan.py", "dns_service.py"],
        },
        "ip6": {
            "source": "platform-registry",
            "description": (
                "IPv6 address family. Standard Linux nftables family for IPv6-only tables "
                "and rules (NAT66 and IPv6 daddr matching)."
            ),
            "used_by": ["firewall_wan.py", "dns_service.py"],
        },
        "inet": {
            "source": "platform-registry",
            "description": (
                "Dual-stack (IPv4+IPv6) address family. Standard Linux nftables family "
                "for tables/rules that apply to both protocols."
            ),
            "used_by": [
                "firewall_wan.py",
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "dns_service.py",
            ],
        },
    },
    "policies": {
        "accept": {
            "source": "platform-registry",
            "description": (
                "Default accept policy. Used as chain default policy. Standard nftables "
                "verdict."
            ),
            "used_by": [
                "firewall_wan.py",
                "policy_firewall.py",
                "dns_service.py",
            ],
        },
        "drop": {
            "source": "platform-registry",
            "description": (
                "Default drop policy. Used as chain default policy for filter chains "
                "on WAN nodes and policy firewall. Standard nftables verdict."
            ),
            "used_by": ["firewall_wan.py", "policy_firewall.py"],
        },
    },
    "verdicts": {
        "accept": {
            "source": "platform-registry",
            "description": (
                "Accept verdict. Allows matching packets. Standard nftables verdict."
            ),
            "used_by": [
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "firewall_wan.py",
            ],
        },
        "drop": {
            "source": "platform-registry",
            "description": (
                "Drop verdict. Drops matching packets. Standard nftables verdict."
            ),
            "used_by": [
                "cpm_firewall_rules.py",
                "policy_firewall.py",
                "firewall_wan.py",
                "dns_service.py",
            ],
        },
        "masquerade": {
            "source": "platform-registry",
            "description": (
                "Masquerade NAT verdict. Used for source NAT on egress interfaces. "
                "Standard nftables NAT verdict."
            ),
            "used_by": ["nat.py", "firewall_wan.py"],
        },
        "snat": {
            "source": "platform-registry",
            "description": (
                "Source NAT verdict. Used for static source NAT to a specific IP. "
                "Standard nftables NAT verdict."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "dnat": {
            "source": "platform-registry",
            "description": (
                "Destination NAT verdict. Standard nftables NAT verdict. Reserved for "
                "future CPM-driven DNAT, currently not emitted by any CM module."
            ),
            "used_by": [],
        },
    },
    "priorities": {
        "0": {
            "source": "platform-registry",
            "description": (
                "Priority 0 filter chains. Default priority for inet filter table chains "
                "(WAN node firewall) and inet fw forward chain (CPM policy firewall)."
            ),
            "used_by": ["firewall_wan.py", "policy_firewall.py"],
        },
        "-300": {
            "source": "platform-registry",
            "description": (
                "Priority -300 (before mangle). Used for inet clab_guard chains "
                "(management egress guard) so the guard executes before any other "
                "filter or mangle chains, blocking all eth0 traffic."
            ),
            "used_by": ["management_egress_guard.py"],
        },
        "-50": {
            "source": "platform-registry",
            "description": (
                "Priority -50 (before default filter). Used for inet clab_dns_guard chains "
                "so DNS guard rules execute before the main policy firewall."
            ),
            "used_by": ["dns_service.py"],
        },
        "100": {
            "source": "platform-registry",
            "description": (
                "Priority 100 NAT postrouting chain. Default priority for ip nat "
                "postrouting in nat.py (NAT module)."
            ),
            "used_by": ["nat.py"],
        },
        "101": {
            "source": "platform-registry",
            "description": (
                "Priority 101 NAT postrouting chain. Used in firewall_wan.py for WAN "
                "node NAT so it executes after the NAT module's chain at priority 100."
            ),
            "used_by": ["firewall_wan.py"],
        },
        "mangle": {
            "source": "platform-registry",
            "description": (
                "nftables constant 'mangle' (resolves to -150). Used for TCP MSS clamping "
                "in inet mangle forward chain. Standard nftables priority keyword."
            ),
            "used_by": ["firewall_wan.py"],
        },
    },
}


# ── Query functions ─────────────────────────────────────────────────────────


def is_registered(category: str, value: str) -> bool:
    """Check if a primitive value is in the registry for the given category."""
    cat = REGISTRY.get(category)
    if cat is None:
        return False
    return value in cat


def get_binding(category: str, value: str) -> Optional[Dict[str, Any]]:
    """Return the binding metadata for a registered primitive, or None."""
    cat = REGISTRY.get(category)
    if cat is None:
        return None
    return cat.get(value)


def unregistered_report(category: str, value: str) -> str:
    """Return a human-readable report string for an unregistered primitive."""
    return (
        f"UNREGISTERED {category} primitive: {value!r} — "
        f"not found in platform-native nftables primitive registry"
    )


def list_registered(category: str) -> List[str]:
    """Return sorted list of registered primitive values for a category."""
    cat = REGISTRY.get(category)
    if cat is None:
        return []
    return sorted(cat.keys())


def all_categories() -> List[str]:
    """Return sorted list of all registry categories."""
    return sorted(REGISTRY.keys())
