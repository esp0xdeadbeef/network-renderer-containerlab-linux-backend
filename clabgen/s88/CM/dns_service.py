from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List
import json


RUNTIME_SCRIPT = Path(__file__).with_name("dns_proxy_runtime.py")
PROTOCOL_SCRIPT = Path(__file__).with_name("dns_proxy_protocol.py")


def _sh(script: str) -> str:
    return "/bin/sh -lc " + json.dumps(script)


def render_dns_service(node: Dict[str, Any]) -> List[str]:
    services = node.get("services")
    if not isinstance(services, dict):
        return []

    dns = services.get("dns")
    if not isinstance(dns, dict):
        return []

    listen = _string_list(dns.get("listen", []))
    if not listen:
        return []

    payload = {
        "listen": ["127.0.0.1", "::1"] + listen,
        "forwarders": _string_list(dns.get("forwarders") or dns.get("upstreams") or []),
        "localRecords": _local_records(dns.get("localRecords", [])),
    }

    return [
        _sh(
            "pkill -f '^python3 /tmp/clabgen-dns-proxy.py' >/dev/null 2>&1 || true\n"
            "cat >/tmp/clabgen-dns-proxy.json <<'JSON'\n"
            + json.dumps(payload, indent=2, sort_keys=True)
            + "\nJSON\n"
            "cat >/tmp/dns_proxy_protocol.py <<'PY'\n"
            + PROTOCOL_SCRIPT.read_text()
            + "PY\n"
            "cat >/tmp/clabgen-dns-proxy.py <<'PY'\n"
            + RUNTIME_SCRIPT.read_text()
            + "PY\n"
            "nohup python3 /tmp/clabgen-dns-proxy.py /tmp/clabgen-dns-proxy.json "
            ">/tmp/clabgen-dns-proxy.log 2>&1 &\n"
        )
    ]


def _string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []

    result: List[str] = []
    for item in value:
        if isinstance(item, str) and item:
            result.append(item)
    return result


def _local_records(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        return []

    records: List[Dict[str, Any]] = []
    for record in value:
        if not isinstance(record, dict):
            continue
        record_name = record.get("name")
        if isinstance(record_name, str) and record_name:
            records.append(record)
    return records
