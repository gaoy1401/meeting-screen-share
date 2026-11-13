from __future__ import annotations

import random
import socket
import threading
import time
from collections.abc import Callable

from .protocol import (
    MAGIC,
    Packet,
    PacketType,
    control_payload,
    decode,
    encode,
    make_packet,
    parse_control,
)
from .rtp import (
    H264Packetizer,
    RTPPacket,
    RTPPayloadType,
    decode_rtp,
    encode_rtp,
    split_annex_b,
)


class MeetingTransport:
    def __init__(self) -> None:
        self.session_id = random.randint(1, 0xFFFFFFFF)
        self.on_state: Callable[[str], None] = lambda _state: None
        self.on_control: Callable[[dict], None] = lambda _body: None
        self.on_audio: Callable[[RTPPacket], None] = lambda _packet: None
        self.on_screen: Callable[[RTPPacket], None] = lambda _packet: None
        self._socket: socket.socket | None = None
        self._running = threading.Event()
        self._sequence = 0
        self._sequence_lock = threading.Lock()
        self._audio_sequence = random.randint(0, 0xFFFF)
        self._video_sequence = random.randint(0, 0xFFFF)
        self._h264_packetizer = H264Packetizer()
        self._thread: threading.Thread | None = None
        self._joined = threading.Event()
        self._join_body: dict | None = None

    def start(self, host: str, port: int, room: str, name: str, token: str) -> None:
        self.stop()
        udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp_socket.settimeout(1.0)
        udp_socket.connect((host, port))
        self._socket = udp_socket
        self._joined.clear()
        self._join_body = {
            "action": "join",
            "room": room,
            "name": name,
            "token": token,
        }
        self._running.set()
        self._thread = threading.Thread(
            target=self._receive_loop,
            name="meeting-udp",
            daemon=True,
        )
        self._thread.start()
        self.send_control(self._join_body)
        self.on_state("正在加入房间…")

    def stop(self) -> None:
        if self._socket is not None and self._running.is_set():
            try:
                self.send_control({"action": "leave"})
            except OSError:
                pass
        self._running.clear()
        self._joined.clear()
        self._join_body = None
        if self._socket is not None:
            self._socket.close()
        self._socket = None

    def send_control(self, body: dict) -> None:
        self._send(PacketType.CONTROL, control_payload(body))

    def send_audio(self, opus: bytes, timestamp: int) -> None:
        if not opus:
            return
        with self._sequence_lock:
            self._audio_sequence = (self._audio_sequence + 1) & 0xFFFF
            sequence = self._audio_sequence
        self._send_rtp(
            RTPPacket(
                marker=True,
                payload_type=RTPPayloadType.OPUS,
                sequence=sequence,
                timestamp=timestamp,
                ssrc=self.session_id,
                payload=opus,
            )
        )

    def send_screen(self, access_unit: bytes, timestamp: int) -> None:
        if not access_unit:
            return
        duplicate_for_recovery = any(
            nal and (nal[0] & 0x1F) in (5, 7, 8)
            for nal in split_annex_b(access_unit)
        )
        packets = self._h264_packetizer.packetize(
            access_unit,
            timestamp,
            self.session_id,
            self._next_video_sequence,
        )
        for packet in packets:
            self._send_rtp(packet)
            if duplicate_for_recovery:
                self._send_rtp(packet)
            time.sleep(0.00015)

    def _next_video_sequence(self) -> int:
        with self._sequence_lock:
            self._video_sequence = (self._video_sequence + 1) & 0xFFFF
            return self._video_sequence

    def _send_rtp(self, packet: RTPPacket) -> None:
        udp_socket = self._socket
        if udp_socket is not None:
            udp_socket.send(encode_rtp(packet))

    def _send(
        self,
        packet_type: PacketType,
        payload: bytes,
        *,
        frame_id: int = 0,
        chunk_index: int = 0,
        chunk_count: int = 0,
    ) -> None:
        udp_socket = self._socket
        if udp_socket is None:
            return
        with self._sequence_lock:
            self._sequence = (self._sequence + 1) & 0xFFFFFFFF
            sequence = self._sequence
        packet = make_packet(
            packet_type,
            self.session_id,
            sequence,
            payload,
            frame_id=frame_id,
            chunk_index=chunk_index,
            chunk_count=chunk_count,
        )
        udp_socket.send(encode(packet))

    def _receive_loop(self) -> None:
        last_heartbeat = time.monotonic()
        last_join = time.monotonic()
        while self._running.is_set():
            udp_socket = self._socket
            if udp_socket is None:
                return
            try:
                data = udp_socket.recv(1200)
                if data.startswith(MAGIC):
                    packet = decode(data)
                    if packet.packet_type is PacketType.CONTROL:
                        body = parse_control(packet.payload)
                        if body.get("action") == "joined":
                            self._joined.set()
                        self.on_control(body)
                else:
                    packet = decode_rtp(data)
                    if packet.ssrc != self.session_id:
                        if packet.payload_type is RTPPayloadType.OPUS:
                            self.on_audio(packet)
                        elif packet.payload_type is RTPPayloadType.H264:
                            self.on_screen(packet)
            except socket.timeout:
                pass
            except (OSError, ValueError) as exc:
                if self._running.is_set():
                    self.on_state(f"网络错误：{exc}")

            now = time.monotonic()
            if not self._joined.is_set() and now - last_join >= 1:
                try:
                    if self._join_body is not None:
                        self.send_control(self._join_body)
                except OSError as exc:
                    self.on_state(f"加入重试失败：{exc}")
                last_join = now
            elif self._joined.is_set() and now - last_heartbeat >= 5:
                try:
                    self.send_control({"action": "heartbeat"})
                except OSError as exc:
                    self.on_state(f"心跳失败：{exc}")
                last_heartbeat = now
