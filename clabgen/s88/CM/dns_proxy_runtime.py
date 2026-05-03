from __future__ import annotations

from typing import Any, Dict
import json
import socket
import struct
import sys
import threading
import time

from dns_proxy_protocol import address_family, forward_udp


def udp_server(config: Dict[str, Any], address: str) -> None:
    family = address_family(address)
    server_socket = socket.socket(family, socket.SOCK_DGRAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((address, 53))
    while True:
        data, peer = server_socket.recvfrom(4096)
        server_socket.sendto(forward_udp(config, data, family), peer)


def tcp_server(config: Dict[str, Any], address: str) -> None:
    family = address_family(address)
    server_socket = socket.socket(family, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((address, 53))
    server_socket.listen(64)
    while True:
        connection, _peer = server_socket.accept()
        thread = threading.Thread(
            target=handle_tcp, args=(config, connection, family), daemon=True
        )
        thread.start()


def handle_tcp(
    config: Dict[str, Any], connection: socket.socket, family: socket.AddressFamily
) -> None:
    try:
        header = connection.recv(2)
        if len(header) != 2:
            return
        query_size = struct.unpack("!H", header)[0]
        query = read_exact(connection, query_size)
        if query is None:
            return
        answer = forward_udp(config, query, family)
        connection.sendall(struct.pack("!H", len(answer)) + answer)
    finally:
        connection.close()


def read_exact(connection: socket.socket, size: int) -> bytes | None:
    data = b""
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def main() -> None:
    config_path = sys.argv[1]
    config = json.loads(open(config_path, encoding="utf-8").read())
    for address in sorted(set(config.get("listen", []))):
        threading.Thread(target=udp_server, args=(config, address), daemon=True).start()
        threading.Thread(target=tcp_server, args=(config, address), daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
