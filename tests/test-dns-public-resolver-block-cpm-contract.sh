#!/usr/bin/env bash
# GAMP-ID: FS-550-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-550-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-580-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.CM.dns_service import render_dns_service


def rendered_for(dns):
    return "\n".join(render_dns_service({"services": {"dns": dns}}))


no_block = rendered_for(
    {
        "listen": ["10.20.0.1"],
        "allowFrom": ["10.20.0.0/24"],
        "forwarders": [],
        "deniedResolverCidrs": [],
        "killSwitch": {"blockPublicResolvers": False},
    }
)

explicit_block = rendered_for(
    {
        "listen": ["10.20.0.1", "fd00:20::1"],
        "allowFrom": ["10.20.0.0/24", "fd00:20::/64"],
        "forwarders": [],
        "deniedResolverCidrs": ["1.1.1.1/32", "2606:4700:4700::1111/128"],
        "killSwitch": {"blockPublicResolvers": True},
    }
)

required = [
    "nft add table inet clab_dns_guard",
    "nft add chain inet clab_dns_guard forward",
    "nft add chain inet clab_dns_guard output",
    "nft flush chain inet clab_dns_guard forward",
    "nft flush chain inet clab_dns_guard output",
    "nft add rule inet clab_dns_guard forward ip daddr 1.1.1.1/32 udp dport 53 drop comment deny-public-dns-forward-leak",
    "nft add rule inet clab_dns_guard forward ip daddr 1.1.1.1/32 tcp dport 53 drop comment deny-public-dns-forward-leak",
    "nft add rule inet clab_dns_guard output ip daddr 1.1.1.1/32 udp dport 53 drop comment deny-public-dns-output-leak",
    "nft add rule inet clab_dns_guard output ip daddr 1.1.1.1/32 tcp dport 53 drop comment deny-public-dns-output-leak",
    "nft add rule inet clab_dns_guard forward ip6 daddr 2606:4700:4700::1111/128 udp dport 53 drop comment deny-public-dns-forward-leak",
    "nft add rule inet clab_dns_guard forward ip6 daddr 2606:4700:4700::1111/128 tcp dport 53 drop comment deny-public-dns-forward-leak",
]
missing = [item for item in required if item not in explicit_block]
if missing:
    raise SystemExit(
        "FAIL dns-public-resolver-block-cpm-contract: missing explicit block rules "
        + ", ".join(missing)
    )

for forbidden in [
    "deny-public-dns-forward-leak",
    "deny-public-dns-output-leak",
    "ip daddr 1.1.1.1/32",
    "ip6 daddr 2606:4700:4700::1111/128",
]:
    if forbidden in no_block:
        raise SystemExit(
            "FAIL dns-public-resolver-block-cpm-contract: renderer invented public DNS block without CPM contract"
        )

if "dport 443" in explicit_block or "meta l4proto" in explicit_block:
    raise SystemExit(
        "FAIL dns-public-resolver-block-cpm-contract: public resolver guard must only classify tcp/udp port 53 DNS traffic"
    )
PY

echo "PASS dns-public-resolver-block-cpm-contract"
