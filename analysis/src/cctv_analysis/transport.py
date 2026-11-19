"""State transport: UDP datagrams (latest wins) and JSONL recording."""

from __future__ import annotations

import json
import socket
from pathlib import Path
from typing import IO, Any

from .state import MusicalState

DEFAULT_PORT = 9870


def encode(state: MusicalState) -> bytes:
    return json.dumps(state.to_dict(), separators=(",", ":"), allow_nan=False).encode()


def parse_addr(s: str) -> tuple[str, int]:
    host, _, port = s.rpartition(":")
    return (host or "127.0.0.1", int(port or DEFAULT_PORT))


class UdpPublisher:
    """Fire-and-forget: a slow or absent receiver never blocks analysis."""

    def __init__(self, addr: tuple[str, int]) -> None:
        self.addr = addr
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sent = 0
        self.dropped = 0

    def send(self, state: MusicalState) -> None:
        try:
            self.sock.sendto(encode(state), self.addr)
            self.sent += 1
        except (BlockingIOError, ConnectionRefusedError):
            self.dropped += 1

    def close(self) -> None:
        self.sock.close()


class JsonlRecorder:
    """Record every state, one JSON object per line, for replay and evaluation."""

    def __init__(self, path: str | Path, header: dict[str, Any]) -> None:
        self.f: IO[str] = Path(path).open("w")  # noqa: SIM115 (closed by close())
        self.f.write(json.dumps({"header": header}) + "\n")

    def send(self, state: MusicalState) -> None:
        self.f.write(encode(state).decode() + "\n")

    def close(self) -> None:
        self.f.close()
