#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
from clabgen.s88.CM.dns_service import render_dns_service

node = {
    "services": {
        "dns": {
            "listen": ["10.90.10.1", "fd42:dead:cafe:10::1"],
            "forwarders": ["1.1.1.1", "2606:4700:4700::1111"],
            "outgoingInterfaces": ["10.90.10.1", "fd42:dead:cafe:10::1"],
        }
    }
}

rendered = "\n".join(render_dns_service(node))
required = [
    '"outgoingInterfaces": [',
    '"10.90.10.1"',
    '"fd42:dead:cafe:10::1"',
    "outgoing_sources_for_family",
    "upstream_socket.bind((source, 0))",
]
missing = [needle for needle in required if needle not in rendered]
if missing:
    raise SystemExit(
        "FAIL dns-service-source-binding: missing rendered DNS source binding "
        + ", ".join(missing)
    )
PY

echo "PASS dns-service-source-binding"
