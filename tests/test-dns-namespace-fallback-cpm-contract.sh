#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="${repo_root}" python3 - <<'PY'
import struct

from clabgen.s88.CM.dns_service import render_dns_service
from clabgen.s88.CM.dns_proxy_protocol import encode_name, namespace_fallback_blocks


def query(name, qtype=1):
    header = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
    return header + encode_name(name) + struct.pack("!HH", qtype, 1)


dns = {
    "listen": ["10.20.0.1"],
    "forwarders": ["1.1.1.1"],
    "namespaceFallback": {
        "defaultPublicRecursionFallback": False,
        "decisions": [
            {
                "requesterScope": "tenant-a",
                "namespace": "tenant-a.lan.",
                "allowedRecordClasses": ["A", "AAAA"],
                "deniedRecordClasses": ["PUBLIC-RECURSION"],
                "failedAnswerReason": "missing-record",
                "action": "block",
                "publicRecursionFallback": False,
                "leakPrevention": "fail-closed",
            },
            {
                "requesterScope": "tenant-b",
                "namespace": "tenant-a.lan.",
                "allowedRecordClasses": ["A", "AAAA"],
                "deniedRecordClasses": ["A", "AAAA", "PUBLIC-RECURSION"],
                "failedAnswerReason": "denied-requester-scope",
                "action": "deny",
                "publicRecursionFallback": False,
                "leakPrevention": "terminal-denial",
            },
            {
                "requesterScope": "tenant-a",
                "namespace": "public.example.",
                "allowedRecordClasses": ["A"],
                "deniedRecordClasses": ["NONE"],
                "failedAnswerReason": "missing-record",
                "action": "fallback",
                "fallbackTarget": "modeled-recursive-dns",
                "publicRecursionFallback": True,
                "leakPrevention": "modeled-fallback",
            },
        ],
    },
}

rendered = "\n".join(render_dns_service({"services": {"dns": dns}}))
for needle in (
    '"namespaceFallback": {',
    '"namespace": "tenant-a.lan."',
    '"failedAnswerReason": "denied-requester-scope"',
    '"publicRecursionFallback": false',
):
    if needle not in rendered:
        raise SystemExit(
            "FAIL dns-namespace-fallback-cpm-contract: rendered DNS proxy JSON missing "
            + needle
        )

payload = {
    "namespaceFallback": dns["namespaceFallback"],
}
if not namespace_fallback_blocks(payload, query("missing.tenant-a.lan.", 1)):
    raise SystemExit("FAIL dns-namespace-fallback-cpm-contract: namespace miss did not block before fallback")

if not namespace_fallback_blocks(payload, query("missing.tenant-a.lan.", 28)):
    raise SystemExit("FAIL dns-namespace-fallback-cpm-contract: denied-scope AAAA miss did not block before fallback")

if namespace_fallback_blocks(payload, query("www.public.example.", 1)):
    raise SystemExit("FAIL dns-namespace-fallback-cpm-contract: modeled fallback decision was blocked")

if namespace_fallback_blocks(payload, query("example.net.", 1)):
    raise SystemExit("FAIL dns-namespace-fallback-cpm-contract: unrelated namespace was blocked")
PY

echo "PASS dns-namespace-fallback-cpm-contract"
