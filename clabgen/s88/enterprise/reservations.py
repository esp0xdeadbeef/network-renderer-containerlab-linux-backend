from __future__ import annotations

from typing import Any, Dict


def _reservation_count(runtime_target: Dict[str, Any]) -> int:
    advertisements = runtime_target.get("advertisements")
    if not isinstance(advertisements, dict):
        return 0

    count = 0
    for family in ("dhcp4", "dhcpv6"):
        entries = advertisements.get(family)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            reservations = entry.get("reservations")
            if isinstance(reservations, list):
                count += len(reservations)
    return count


def reject_unsupported_reservations(site: Dict[str, Any]) -> None:
    runtime_targets = site.get("runtimeTargets")
    if not isinstance(runtime_targets, dict):
        return

    for rt_name, runtime_target in runtime_targets.items():
        if not isinstance(runtime_target, dict):
            continue
        if _reservation_count(runtime_target) > 0:
            raise ValueError(
                "containerlab-linux renderer does not materialize DHCP reservations; "
                f"unsupported reservations present at runtimeTargets.{rt_name}.advertisements"
            )
