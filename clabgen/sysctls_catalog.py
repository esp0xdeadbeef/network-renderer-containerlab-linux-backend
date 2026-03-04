from __future__ import annotations

from typing import Dict


def default_sysctls() -> Dict[str, str]:
    """
    Declarative sysctl catalog for topology defaults.

    This intentionally does NOT parse code or scrape shell commands.
    If you want a sysctl in topology.defaults.sysctls, add it here.
    """
    return {
        # matches fabric.clab.yml.working-up-downstream-static
        "net.ipv4.ip_forward": "1",
        "net.ipv6.conf.all.forwarding": "1",
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.default.rp_filter": "0",
    }
