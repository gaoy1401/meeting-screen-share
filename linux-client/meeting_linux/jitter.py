from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from .rtp import RTPPacket, RTPPayloadType


@dataclass
class _Stream:
    expected_sequence: int | None = None
    pending: dict[int, bytes] = field(default_factory=dict)
    started: bool = False


class AudioJitterBuffer:
    def __init__(self, on_payload: Callable[[int, bytes], None]) -> None:
        self._on_payload = on_payload
        self._streams: dict[int, _Stream] = {}
        self._lock = threading.Lock()
        self._running = threading.Event()
        self._running.set()
        self._thread = threading.Thread(
            target=self._run,
            name="meeting-audio-jitter",
            daemon=True,
        )
        self._thread.start()

    def ingest(self, packet: RTPPacket) -> None:
        if packet.payload_type is not RTPPayloadType.OPUS or not packet.payload:
            return
        with self._lock:
            stream = self._streams.setdefault(packet.ssrc, _Stream())
            if stream.expected_sequence is None:
                stream.expected_sequence = packet.sequence
            stream.pending[packet.sequence] = packet.payload
            if len(stream.pending) >= 3:
                stream.started = True

    def reset(self) -> None:
        with self._lock:
            self._streams.clear()

    def stop(self) -> None:
        self._running.clear()

    def _run(self) -> None:
        next_tick = time.monotonic() + 0.06
        while self._running.is_set():
            delay = next_tick - time.monotonic()
            if delay > 0:
                time.sleep(min(delay, 0.02))
                continue
            next_tick += 0.02
            ready: list[tuple[int, bytes]] = []
            with self._lock:
                for ssrc, stream in self._streams.items():
                    if not stream.started or stream.expected_sequence is None:
                        continue
                    sequence = stream.expected_sequence
                    payload = stream.pending.pop(sequence, None)
                    if payload is not None:
                        stream.expected_sequence = (sequence + 1) & 0xFFFF
                        ready.append((ssrc, payload))
                    elif stream.pending:
                        stream.expected_sequence = (sequence + 1) & 0xFFFF
                    else:
                        stream.started = False
            for ssrc, payload in ready:
                self._on_payload(ssrc, payload)
