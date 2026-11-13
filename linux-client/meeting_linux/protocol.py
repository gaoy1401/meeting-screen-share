from __future__ import annotations

import json
import struct
import time
from dataclasses import dataclass
from enum import IntEnum

MAGIC = b"MSH1"
VERSION = 1
HEADER = struct.Struct("!4sBBHIIIHHQ")
HEADER_SIZE = HEADER.size
MAX_DATAGRAM_SIZE = 1200
MAX_PAYLOAD_SIZE = MAX_DATAGRAM_SIZE - HEADER_SIZE


class PacketType(IntEnum):
    CONTROL = 1
    AUDIO = 2
    SCREEN = 3


@dataclass(frozen=True)
class Packet:
    packet_type: PacketType
    flags: int
    session_id: int
    sequence: int
    frame_id: int
    chunk_index: int
    chunk_count: int
    timestamp_ms: int
    payload: bytes


def encode(packet: Packet) -> bytes:
    if len(packet.payload) > MAX_PAYLOAD_SIZE:
        raise ValueError("payload exceeds maximum UDP payload")
    header = HEADER.pack(
        MAGIC,
        VERSION,
        int(packet.packet_type),
        packet.flags,
        packet.session_id,
        packet.sequence,
        packet.frame_id,
        packet.chunk_index,
        packet.chunk_count,
        packet.timestamp_ms,
    )
    return header + packet.payload


def decode(data: bytes) -> Packet:
    if len(data) < HEADER_SIZE:
        raise ValueError("packet is shorter than fixed header")
    if len(data) > MAX_DATAGRAM_SIZE:
        raise ValueError("packet exceeds maximum datagram size")

    (
        magic,
        version,
        packet_type,
        flags,
        session_id,
        sequence,
        frame_id,
        chunk_index,
        chunk_count,
        timestamp_ms,
    ) = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise ValueError("invalid packet magic")
    if version != VERSION:
        raise ValueError("unsupported protocol version")

    kind = PacketType(packet_type)
    if kind is PacketType.SCREEN and (
        chunk_count == 0 or chunk_index >= chunk_count
    ):
        raise ValueError("invalid screen chunk metadata")
    return Packet(
        packet_type=kind,
        flags=flags,
        session_id=session_id,
        sequence=sequence,
        frame_id=frame_id,
        chunk_index=chunk_index,
        chunk_count=chunk_count,
        timestamp_ms=timestamp_ms,
        payload=data[HEADER_SIZE:],
    )


def control_payload(body: dict) -> bytes:
    return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def parse_control(payload: bytes) -> dict:
    body = json.loads(payload.decode("utf-8"))
    if not isinstance(body, dict):
        raise ValueError("control payload must be an object")
    return body


def make_packet(
    packet_type: PacketType,
    session_id: int,
    sequence: int,
    payload: bytes,
    *,
    frame_id: int = 0,
    chunk_index: int = 0,
    chunk_count: int = 0,
) -> Packet:
    return Packet(
        packet_type=packet_type,
        flags=0,
        session_id=session_id,
        sequence=sequence,
        frame_id=frame_id,
        chunk_index=chunk_index,
        chunk_count=chunk_count,
        timestamp_ms=int(time.time() * 1000),
        payload=payload,
    )

