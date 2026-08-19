#!/usr/bin/env python3
"""Minimal Source RCON client.

ASA speaks the standard Valve RCON protocol, so this is only ~60 lines and saves
pulling in a whole extra package just to send SaveWorld and DoExit on shutdown.

Usage: rcon.py <host> <port> <password> <command> [<command> ...]
"""

import socket
import struct
import sys

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_AUTH_RESPONSE = 2

TIMEOUT = 10


def encode(request_id: int, packet_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, packet_type) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_exactly(sock: socket.socket, count: int) -> bytes:
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError("connection closed by server")
        buf += chunk
    return buf


def decode(sock: socket.socket):
    size = struct.unpack("<i", read_exactly(sock, 4))[0]
    payload = read_exactly(sock, size)
    request_id, packet_type = struct.unpack("<ii", payload[:8])
    body = payload[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, body


def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    host, port, password = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    commands = sys.argv[4:]

    try:
        with socket.create_connection((host, port), timeout=TIMEOUT) as sock:
            sock.settimeout(TIMEOUT)

            sock.sendall(encode(1, SERVERDATA_AUTH, password))
            request_id, packet_type, _ = decode(sock)
            # Some servers emit an empty RESPONSE_VALUE before the auth result.
            if packet_type != SERVERDATA_AUTH_RESPONSE:
                request_id, _, _ = decode(sock)
            if request_id == -1:
                print("RCON authentication failed", file=sys.stderr)
                return 1

            for index, command in enumerate(commands, start=2):
                sock.sendall(encode(index, SERVERDATA_EXECCOMMAND, command))
                _, _, body = decode(sock)
                body = body.strip()
                if body:
                    print(body)
    except (OSError, ConnectionError, struct.error) as exc:
        print(f"RCON error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
