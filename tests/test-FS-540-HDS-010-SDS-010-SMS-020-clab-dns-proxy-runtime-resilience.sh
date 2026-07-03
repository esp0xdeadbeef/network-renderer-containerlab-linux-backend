#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}/clabgen/s88/CM:${repo_root}" python3 - <<'PY'
import socket
import struct

import clabgen.s88.CM.dns_proxy_runtime as runtime
from clabgen.s88.CM.dns_proxy_protocol import encode_name


def query(name):
    return (
        struct.pack("!HHHHHH", 0x5402, 0x0100, 1, 0, 0, 0)
        + encode_name(name)
        + struct.pack("!HH", 1, 1)
    )


def raising_forwarder(_config, _query, _family):
    raise TimeoutError("seeded upstream timeout")


original = runtime.forward_udp
try:
    runtime.forward_udp = raising_forwarder
    answer = runtime._resolve_or_servfail({}, query("cache.nixos.org."), socket.AF_INET)
finally:
    runtime.forward_udp = original

if answer[:2] != b"\x54\x02":
    raise SystemExit("FAIL DNS runtime resilience: response did not preserve query id")

flags = struct.unpack("!H", answer[2:4])[0]
rcode = flags & 0x000F
if rcode != 2:
    raise SystemExit(
        f"FAIL DNS runtime resilience: expected SERVFAIL rcode 2, got {rcode}"
    )

print("PASS FS-540-HDS-010-SDS-010-SMS-020 CLAB DNS proxy runtime resilience")
PY
