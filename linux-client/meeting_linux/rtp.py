from __future__ import annotations

import struct
from collections import deque
from dataclasses import dataclass
from enum import IntEnum

RTP_HEADER = struct.Struct("!BBHII")
RTP_HEADER_SIZE = RTP_HEADER.size
MAX_DATAGRAM_SIZE = 1200
MAX_RTP_PAYLOAD_SIZE = MAX_DATAGRAM_SIZE - RTP_HEADER_SIZE


class RTPPayloadType(IntEnum):
    H264 = 96
    OPUS = 111


@dataclass(frozen=True)
class RTPPacket:
    marker: bool
    payload_type: RTPPayloadType
    sequence: int
    timestamp: int
    ssrc: int
    payload: bytes


def encode_rtp(packet: RTPPacket) -> bytes:
    if len(packet.payload) > MAX_RTP_PAYLOAD_SIZE:
        raise ValueError("RTP payload exceeds maximum size")
    return RTP_HEADER.pack(
        0x80,
        (0x80 if packet.marker else 0) | int(packet.payload_type),
        packet.sequence,
        packet.timestamp,
        packet.ssrc,
    ) + packet.payload


def decode_rtp(data: bytes) -> RTPPacket:
    if len(data) < RTP_HEADER_SIZE:
        raise ValueError("RTP packet is shorter than fixed header")
    if len(data) > MAX_DATAGRAM_SIZE:
        raise ValueError("RTP packet exceeds maximum datagram size")
    first, second, sequence, timestamp, ssrc = RTP_HEADER.unpack_from(data)
    if first >> 6 != 2:
        raise ValueError("unsupported RTP version")
    if first & 0x3F:
        raise ValueError("RTP padding, extension and CSRC are not supported")
    try:
        payload_type = RTPPayloadType(second & 0x7F)
    except ValueError as exc:
        raise ValueError("unknown RTP payload type") from exc
    return RTPPacket(
        marker=bool(second & 0x80),
        payload_type=payload_type,
        sequence=sequence,
        timestamp=timestamp,
        ssrc=ssrc,
        payload=data[RTP_HEADER_SIZE:],
    )


def split_annex_b(data: bytes) -> list[bytes]:
    starts: list[tuple[int, int]] = []
    index = 0
    while index + 3 <= len(data):
        if data[index : index + 4] == b"\x00\x00\x00\x01":
            starts.append((index, 4))
            index += 4
        elif data[index : index + 3] == b"\x00\x00\x01":
            starts.append((index, 3))
            index += 3
        else:
            index += 1
    if not starts:
        return [data] if data else []
    units = []
    for position, (offset, prefix) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(data)
        if offset + prefix < end:
            units.append(data[offset + prefix : end])
    return units


class H264Packetizer:
    def packetize(
        self,
        access_unit: bytes,
        timestamp: int,
        ssrc: int,
        next_sequence: callable,
    ) -> list[RTPPacket]:
        nal_units = split_annex_b(access_unit)
        packets: list[RTPPacket] = []
        for nal_index, nal in enumerate(nal_units):
            if not nal:
                continue
            last_nal = nal_index == len(nal_units) - 1
            if len(nal) <= MAX_RTP_PAYLOAD_SIZE:
                packets.append(
                    RTPPacket(
                        marker=last_nal,
                        payload_type=RTPPayloadType.H264,
                        sequence=next_sequence(),
                        timestamp=timestamp,
                        ssrc=ssrc,
                        payload=nal,
                    )
                )
                continue

            nal_header = nal[0]
            fu_indicator = (nal_header & 0xE0) | 28
            nal_type = nal_header & 0x1F
            fragment_size = MAX_RTP_PAYLOAD_SIZE - 2
            offset = 1
            while offset < len(nal):
                end = min(offset + fragment_size, len(nal))
                fu_header = nal_type
                if offset == 1:
                    fu_header |= 0x80
                if end == len(nal):
                    fu_header |= 0x40
                packets.append(
                    RTPPacket(
                        marker=last_nal and end == len(nal),
                        payload_type=RTPPayloadType.H264,
                        sequence=next_sequence(),
                        timestamp=timestamp,
                        ssrc=ssrc,
                        payload=bytes((fu_indicator, fu_header)) + nal[offset:end],
                    )
                )
                offset = end
        return packets


@dataclass
class _H264Stream:
    timestamp: int | None = None
    expected_sequence: int | None = None
    access_unit: bytearray | None = None
    fragmented_nal: bytearray | None = None
    damaged: bool = False

    def __post_init__(self) -> None:
        if self.access_unit is None:
            self.access_unit = bytearray()
        if self.fragmented_nal is None:
            self.fragmented_nal = bytearray()


class H264Depacketizer:
    def __init__(self) -> None:
        self._streams: dict[int, _H264Stream] = {}
        self._recent_packets: set[tuple[int, int, int]] = set()
        self._recent_packet_order: deque[tuple[int, int, int]] = deque()

    def ingest(self, packet: RTPPacket) -> bytes | None:
        if packet.payload_type is not RTPPayloadType.H264 or not packet.payload:
            return None
        current = (packet.ssrc, packet.timestamp, packet.sequence)
        if current in self._recent_packets:
            return None
        self._recent_packets.add(current)
        self._recent_packet_order.append(current)
        if len(self._recent_packet_order) > 8192:
            for _ in range(2048):
                self._recent_packets.discard(
                    self._recent_packet_order.popleft()
                )
        state = self._streams.get(packet.ssrc, _H264Stream())
        if state.timestamp != packet.timestamp:
            state = _H264Stream(timestamp=packet.timestamp)
        if (
            state.expected_sequence is not None
            and packet.sequence != state.expected_sequence
        ):
            state.damaged = True
            state.fragmented_nal.clear()
        state.expected_sequence = (packet.sequence + 1) & 0xFFFF

        nal_type = packet.payload[0] & 0x1F
        if nal_type == 28 and len(packet.payload) >= 3:
            fu_header = packet.payload[1]
            if fu_header & 0x80:
                original_header = (packet.payload[0] & 0xE0) | (fu_header & 0x1F)
                state.fragmented_nal = bytearray(b"\x00\x00\x00\x01")
                state.fragmented_nal.append(original_header)
                state.fragmented_nal.extend(packet.payload[2:])
            elif state.fragmented_nal:
                state.fragmented_nal.extend(packet.payload[2:])
            else:
                state.damaged = True
            if fu_header & 0x40 and state.fragmented_nal:
                state.access_unit.extend(state.fragmented_nal)
                state.fragmented_nal.clear()
        elif 0 < nal_type < 24:
            state.access_unit.extend(b"\x00\x00\x00\x01")
            state.access_unit.extend(packet.payload)
        else:
            state.damaged = True

        if packet.marker:
            result = (
                bytes(state.access_unit)
                if not state.damaged and not state.fragmented_nal
                else None
            )
            self._streams.pop(packet.ssrc, None)
            return result
        self._streams[packet.ssrc] = state
        return None

    def reset(self) -> None:
        self._streams.clear()
        self._recent_packets.clear()
        self._recent_packet_order.clear()
