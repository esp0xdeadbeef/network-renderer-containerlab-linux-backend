import ipaddress
import logging
import socket
import struct

logger = logging.getLogger(__name__)

_TRACE = "FS-310-HDS-010-SDS-010-SMS-110"


def encode_name(name):
    normalized_name = name.rstrip(".")
    if not normalized_name:
        return b"\x00"

    parts = []
    for part in normalized_name.split("."):
        parts.append(bytes([len(part)]) + part.encode("ascii"))
    return b"".join(parts) + b"\x00"


def parse_question(query):
    if len(query) < 12:
        return None

    position = 12
    labels = []
    while position < len(query):
        label_size = query[position]
        position += 1
        if label_size == 0:
            break
        if label_size & 0xC0 or position + label_size > len(query):
            return None
        label_data = query[position : position + label_size]
        labels.append(label_data.decode("ascii", "ignore").lower())
        position += label_size

    if position + 4 > len(query):
        return None

    question_type, question_class = struct.unpack("!HH", query[position : position + 4])
    question_wire = query[12 : position + 4]
    return ".".join(labels) + ".", question_type, question_class, question_wire


def local_answer(config, query):
    question = parse_question(query)
    if question is None:
        return None

    query_name, query_type, query_class, question_wire = question
    answers = []
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

    header = query[:2] + b"\x81\x80" + query[4:6]
    counts = struct.pack("!H", len(answers)) + b"\x00\x00\x00\x00"
    return header + counts + question_wire + body


def namespace_fallback_blocks(config, query):
    question = parse_question(query)
    if question is None:
        return False

    query_name, query_type, _query_class, _question_wire = question
    record_class = {1: "A", 28: "AAAA", 255: "ANY"}.get(query_type, f"TYPE{query_type}")
    namespace_fallback = config.get("namespaceFallback", {})
    if not isinstance(namespace_fallback, dict):
        return False

    for decision in namespace_fallback.get("decisions", []):
        if not isinstance(decision, dict):
            continue
        action = decision.get("action")
        if action not in ("block", "deny"):
            continue
        if decision.get("publicRecursionFallback", False):
            continue
        namespace = decision.get("namespace")
        if not isinstance(namespace, str) or not namespace:
            continue
        namespace = namespace.rstrip(".").lower() + "."
        if not query_name.endswith(namespace):
            continue
        allowed_classes = decision.get("allowedRecordClasses", [])
        denied_classes = decision.get("deniedRecordClasses", [])
        if class_list_has(allowed_classes, record_class):
            return True
        if class_list_has(denied_classes, record_class):
            return True
        if class_list_has(denied_classes, "PUBLIC-RECURSION"):
            return True

    return False


def class_list_has(value, expected):
    if not isinstance(value, list):
        return False
    for item in value:
        if item == expected:
            return True
    return False


def add_record_answers(answers, query_type, record):
    if query_type in (1, 255):
        for address in record.get("a", []):
            add_address_answer(answers, 1, socket.AF_INET, address)

    if query_type in (28, 255):
        for address in record.get("aaaa", []):
            add_address_answer(answers, 28, socket.AF_INET6, address)


def add_address_answer(answers, record_type, address_family, address):
    if not isinstance(address, str):
        return
    try:
        answers.append((record_type, socket.inet_pton(address_family, address)))
    except OSError:
        return


def address_family(address):
    if ipaddress.ip_address(address).version == 6:
        return socket.AF_INET6
    return socket.AF_INET


def servfail(query):
    if len(query) < 12:
        return query
    header = query[:2] + b"\x81\x82" + query[4:6]
    return header + b"\x00\x00\x00\x00\x00\x00" + query[12:]


def forward_udp(config, query, family):
    answer = local_answer(config, query)
    if answer is not None:
        return answer
    if namespace_fallback_blocks(config, query):
        return servfail(query)

    outgoing_sources = outgoing_sources_for_family(config, family)
    for forwarder in config.get("forwarders", []):
        if not isinstance(forwarder, str):
            continue
        try:
            fam = address_family(forwarder)
        except ValueError as e:
            logger.error(
                "%s: malformed DNS forwarder address '%s': %s", _TRACE, forwarder, e
            )
            continue
        if fam != family:
            continue
        return query_forwarder(query, family, forwarder, outgoing_sources)

    return servfail(query)


def outgoing_sources_for_family(config, family):
    sources = []
    for source in config.get("outgoingInterfaces", []):
        if not isinstance(source, str):
            continue
        try:
            if address_family(source) == family:
                sources.append(source)
        except ValueError:
            continue
    return sources


def query_forwarder(query, family, forwarder, outgoing_sources):
    sources = outgoing_sources or [""]
    last_error = None
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
