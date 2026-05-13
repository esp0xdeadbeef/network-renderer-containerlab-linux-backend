from __future__ import annotations

from typing import Any, Dict, List, Tuple
import ipaddress
import socket
import struct


Question = Tuple[str, int, int, bytes]
Answer = Tuple[int, bytes]


def encode_name(name: str) -> bytes:
    normalized_name = name.rstrip(".")
    if not normalized_name:
        return b"\x00"

    parts: List[bytes] = []
    for part in normalized_name.split("."):
        parts.append(bytes([len(part)]) + part.encode("ascii"))
    return b"".join(parts) + b"\x00"


def parse_question(query: bytes) -> Question | None:
    if len(query) < 12:
        return None

    position = 12
    labels: List[str] = []
    while position < len(query):
        label_size = query[position]
        position += 1
        if label_size == 0:
            break
        if label_size & 0xC0 or position + label_size > len(query):
            return None
        label = (
            query[position : position + label_size].decode("ascii", "ignore").lower()
        )
        labels.append(label)
        position += label_size

    if position + 4 > len(query):
        return None

    question_type, question_class = struct.unpack("!HH", query[position : position + 4])
    return (
        ".".join(labels) + ".",
        question_type,
        question_class,
        query[12 : position + 4],
    )


def local_answer(config: Dict[str, Any], query: bytes) -> bytes | None:
    question = parse_question(query)
    if question is None:
        return None

    query_name, query_type, query_class, question_wire = question
    answers: List[Answer] = []
    for record in config.get("localRecords", []):
        record_name = str(record.get("name", "")).rstrip(".").lower() + "."
        if record_name != query_name:
            continue
        add_record_answers(answers, query_type, record)

    if not answers:
        return None

    body = b""
    for record_type, record_data in answers:
        body += encode_name(query_name)
        body += struct.pack("!HHIH", record_type, query_class, 60, len(record_data))
        body += record_data

    return (
        query[:2]
        + b"\x81\x80"
        + query[4:6]
        + struct.pack("!H", len(answers))
        + b"\x00\x00\x00\x00"
        + question_wire
        + body
    )


def add_record_answers(
    answers: List[Answer], query_type: int, record: Dict[str, Any]
) -> None:
    if query_type in (1, 255):
        for address in record.get("a", []):
            add_address_answer(answers, 1, socket.AF_INET, address)

    if query_type in (28, 255):
        for address in record.get("aaaa", []):
            add_address_answer(answers, 28, socket.AF_INET6, address)


def add_address_answer(
    answers: List[Answer],
    record_type: int,
    address_family: socket.AddressFamily,
    address: Any,
) -> None:
    if not isinstance(address, str):
        return
    try:
        answers.append((record_type, socket.inet_pton(address_family, address)))
    except OSError:
        return


def address_family(address: str) -> socket.AddressFamily:
    if ipaddress.ip_address(address).version == 6:
        return socket.AF_INET6
    return socket.AF_INET


def servfail(query: bytes) -> bytes:
    if len(query) < 12:
        return query
    return (
        query[:2] + b"\x81\x82" + query[4:6] + b"\x00\x00\x00\x00\x00\x00" + query[12:]
    )


def forward_udp(
    config: Dict[str, Any], query: bytes, family: socket.AddressFamily
) -> bytes:
    answer = local_answer(config, query)
    if answer is not None:
        return answer

    outgoing_sources = outgoing_sources_for_family(config, family)
    for forwarder in config.get("forwarders", []):
        if not isinstance(forwarder, str):
            continue
        try:
            if address_family(forwarder) != family:
                continue
            return query_forwarder(query, family, forwarder, outgoing_sources)
        except Exception:
            continue

    return servfail(query)


def outgoing_sources_for_family(
    config: Dict[str, Any], family: socket.AddressFamily
) -> List[str]:
    sources: List[str] = []
    for source in config.get("outgoingInterfaces", []):
        if not isinstance(source, str):
            continue
        try:
            if address_family(source) == family:
                sources.append(source)
        except ValueError:
            continue
    return sources


def query_forwarder(
    query: bytes,
    family: socket.AddressFamily,
    forwarder: str,
    outgoing_sources: List[str],
) -> bytes:
    sources = outgoing_sources or [""]
    last_error: Exception | None = None
    for source in sources:
        upstream_socket = socket.socket(family, socket.SOCK_DGRAM)
        try:
            upstream_socket.settimeout(2)
            if source:
                upstream_socket.bind((source, 0))
            upstream_socket.sendto(query, (forwarder, 53))
            data, _peer = upstream_socket.recvfrom(4096)
            return data
        except Exception as error:
            last_error = error
        finally:
            upstream_socket.close()
    if last_error is not None:
        raise last_error
    raise RuntimeError("no DNS forwarder source attempted")
