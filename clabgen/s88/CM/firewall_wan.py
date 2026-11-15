from __future__ import annotations

from typing import Dict, Any, List


def _render_base_filter(wan_if: str) -> List[str]:
    # CPM_GAP FS-310-HDS-010-SDS-010-SMS-130/170:
    # The input policy and anti-spoof base rules are hardcoded without CPM
    # firewall intent authority. CPM should provide wanFirewallPolicy
    # (anti-spoofing, management allow, input policy).
    # MSS clamping is NOT part of this gap: WAN clamp authority comes from the
    # NAT intent, and low-MTU interfaces come from the target's
    # clampMssInterfaces record (see render()).
    return [
        # Scoped table management: add table (idempotent), then flush its
        # contents. Replaces old `nft flush ruleset` which destroyed all rules.
        "nft add table inet filter",
        "nft flush table inet filter",
        "nft 'add chain inet filter input { type filter hook input priority 0 ; policy drop ; }'",
        "nft 'add chain inet filter forward { type filter hook forward priority 0 ; policy accept ; }'",
        "nft 'add chain inet filter output { type filter hook output priority 0 ; policy accept ; }'",
        "nft add rule inet filter input iif lo accept",
        "nft add rule inet filter input ct state established,related accept",
        "nft add rule inet filter input ct state invalid drop",
        "nft add rule inet filter input meta l4proto icmpv6 accept",
        f'nft add rule inet filter input iifname "{wan_if}" ip saddr {{ 0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4 }} drop',
        f'nft add rule inet filter input iifname "{wan_if}" ip6 saddr {{ ::1,fc00::/7,fe80::/10 }} drop',
        f'nft add rule inet filter input iifname != "{wan_if}" tcp dport 22 accept',
        "nft add rule inet filter forward ct state established,related accept",
        "nft add rule inet filter forward ct state invalid drop",
        f'nft add rule inet filter forward iifname "{wan_if}" ip saddr {{ 10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16 }} drop',
        f'nft add rule inet filter forward iifname "{wan_if}" ip6 saddr fc00::/7 drop',
    ]


def _mangle_commands(clamp_interfaces: List[str]) -> List[str]:
    """Clamp TCP MSS on the given egress interfaces (one mangle table)."""
    if not clamp_interfaces:
        return []
    commands = [
        "nft add table inet mangle",
        "nft flush table inet mangle",
        "nft 'add chain inet mangle forward { type filter hook forward priority mangle ; policy accept ; }'",
    ]
    for interface_name in clamp_interfaces:
        commands.append(
            f'nft add rule inet mangle forward oifname "{interface_name}" '
            "tcp flags syn tcp option maxseg size set rt mtu"
        )
    return commands


def render(input_data: Dict[str, Any]) -> List[str]:
    wan_interfaces = input_data.get("wan_interfaces", [])
    if not isinstance(wan_interfaces, list):
        return []

    clamp_interfaces = input_data.get("clamp_interfaces", [])
    if not isinstance(clamp_interfaces, list):
        clamp_interfaces = []
    clamp_interfaces = [
        interface_name
        for interface_name in clamp_interfaces
        if isinstance(interface_name, str) and interface_name
    ]
    clamp_interfaces = [
        interface_name
        for interface_name in clamp_interfaces
        if interface_name not in wan_interfaces
    ]

    masquerade = input_data.get("masquerade", {})
    if not isinstance(masquerade, dict):
        masquerade = {}

    oifnames = masquerade.get("oifnames", [])
    if not isinstance(oifnames, list):
        oifnames = []
    normalized_oifnames: List[str] = []
    for interface_name in oifnames:
        if isinstance(interface_name, str) and interface_name:
            normalized_oifnames.append(interface_name)
    oifnames = normalized_oifnames

    enable_nat4 = bool(masquerade.get("ipv4", False))
    enable_nat6 = bool(masquerade.get("ipv6", False))

    saddr4 = masquerade.get("saddr4", [])
    if not isinstance(saddr4, list):
        saddr4 = []
    normalized_saddr4: List[str] = []
    for source_prefix in saddr4:
        if isinstance(source_prefix, str) and source_prefix:
            normalized_saddr4.append(source_prefix)
    saddr4 = normalized_saddr4

    saddr6 = masquerade.get("saddr6", [])
    if not isinstance(saddr6, list):
        saddr6 = []
    normalized_saddr6: List[str] = []
    for source_prefix in saddr6:
        if isinstance(source_prefix, str) and source_prefix:
            normalized_saddr6.append(source_prefix)
    saddr6 = normalized_saddr6

    # Read the SNAT IP from the input data — computed by the caller using
    # the shared _wan_index counter so it matches the /32 IP assigned by
    # linux_wan_dynamic.py.
    snat_ip = masquerade.get("snat_ip")

    cmds: List[str] = []
    first = True

    # If no WAN interfaces exist (common in CLAB labs where "internet" is the
    # management network), we still allow inventory-driven masquerading without
    # constructing WAN-filtering rules.
    if not wan_interfaces:
        if oifnames and enable_nat4 and saddr4:
            cmds.extend(
                [
                    "nft add table ip nat",
                    # CPM_GAP: NAT chain policy accept is standard behavior; CPM should provide natChainPolicy.
                    "nft 'add chain ip nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
                ]
            )
            srcset = ",".join(saddr4)
            for oif in oifnames:
                cmds.append(
                    f'nft add rule ip nat postrouting ip saddr {{ {srcset} }} oifname "{oif}" masquerade'
                )

        if oifnames and enable_nat6 and saddr6:
            cmds.extend(
                [
                    "nft add table ip6 nat",
                    # CPM_GAP: NAT chain policy accept is standard behavior; CPM should provide natChainPolicy.
                    "nft 'add chain ip6 nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
                ]
            )
            srcset6 = ",".join(saddr6)
            for oif in oifnames:
                cmds.append(
                    f'nft add rule ip6 nat postrouting ip6 saddr {{ {srcset6} }} oifname "{oif}" masquerade'
                )

        cmds.extend(_mangle_commands(clamp_interfaces))
        return cmds

    for wan_if in wan_interfaces:
        if not isinstance(wan_if, str) or not wan_if:
            continue
        if first:
            cmds.extend(_render_base_filter(wan_if))
            first = False
        else:
            cmds.extend(
                [
                    f'nft add rule inet filter input iifname "{wan_if}" ip saddr {{ 0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4 }} drop',
                    f'nft add rule inet filter input iifname "{wan_if}" ip6 saddr {{ ::1,fc00::/7,fe80::/10 }} drop',
                    f'nft add rule inet filter input iifname != "{wan_if}" tcp dport 22 accept',
                    f'nft add rule inet filter forward iifname "{wan_if}" ip saddr {{ 10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16 }} drop',
                    f'nft add rule inet filter forward iifname "{wan_if}" ip6 saddr fc00::/7 drop',
                ]
            )

    # WAN clamp authority comes from the NAT intent; low-MTU interfaces come
    # from the target's clampMssInterfaces record. Both are emitted once.
    cmds.extend(_mangle_commands(wan_interfaces + clamp_interfaces))

    # NAT is inventory-driven and independent from which interfaces are treated as WAN for filtering.
    if oifnames and enable_nat4 and saddr4:
        cmds.extend(
            [
                "nft add table ip nat",
                # CPM_GAP: NAT chain policy accept is standard behavior; CPM should provide natChainPolicy.
                "nft 'add chain ip nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
            ]
        )
        srcset = ",".join(saddr4)
        for oif in oifnames:
            if snat_ip:
                cmds.append(
                    f'nft add rule ip nat postrouting ip saddr {{ {srcset} }} oifname "{oif}" snat to {snat_ip}'
                )
            else:
                cmds.append(
                    f'nft add rule ip nat postrouting ip saddr {{ {srcset} }} oifname "{oif}" masquerade'
                )

    if oifnames and enable_nat6 and saddr6:
        cmds.extend(
            [
                "nft add table ip6 nat",
                # CPM_GAP: NAT chain policy accept is standard behavior; CPM should provide natChainPolicy.
                "nft 'add chain ip6 nat postrouting { type nat hook postrouting priority 101 ; policy accept ; }'",
            ]
        )
        srcset6 = ",".join(saddr6)
        for oif in oifnames:
            cmds.append(
                f'nft add rule ip6 nat postrouting ip6 saddr {{ {srcset6} }} oifname "{oif}" masquerade'
            )

    return cmds
