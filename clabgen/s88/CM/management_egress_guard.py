from __future__ import annotations

from typing import Any, Dict, List


def render(input_data: Dict[str, Any]) -> List[str]:
    interface_name = input_data.get("interface")
    if not isinstance(interface_name, str) or not interface_name:
        raise ValueError(
            "GAMP: FS-310-HDS-010-SDS-010-SMS-110 — "
            "management interface must be specified, cannot default to eth0"
        )

    return [
        "nft add table inet clab_guard",
        "nft 'add chain inet clab_guard output { type filter hook output priority -300 ; policy accept ; }'",
        "nft 'add chain inet clab_guard forward { type filter hook forward priority -300 ; policy accept ; }'",
        f'nft add rule inet clab_guard output oifname "{interface_name}" drop',
        f'nft add rule inet clab_guard forward oifname "{interface_name}" drop',
    ]
