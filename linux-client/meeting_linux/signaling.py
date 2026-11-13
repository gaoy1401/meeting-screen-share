from __future__ import annotations

import json
import socket
import threading
import time
from collections.abc import Callable


class SignalingTransport:
    def __init__(self) -> None:
        self.on_state: Callable[[str], None] = lambda _state: None
        self.on_control: Callable[[dict], None] = lambda _body: None
        self._socket: socket.socket | None = None
        self._running = threading.Event()
        self._send_lock = threading.Lock()
        self._thread: threading.Thread | None = None

    def start(
        self,
        host: str,
        port: int,
        room: str,
        name: str,
        session_id: int,
        media_transport: str = "udp",
    ) -> None:
        self.stop()
        self.on_state("正在连接可靠信令…")
        tcp_socket = socket.create_connection((host, port), timeout=5)
        tcp_socket.settimeout(1.0)
        tcp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self._socket = tcp_socket
        self._running.set()
        self._thread = threading.Thread(
            target=self._receive_loop,
            name="meeting-tcp-signaling",
            daemon=True,
        )
        self._thread.start()
        self.send(
            {
                "action": "join",
                "room": room,
                "name": name,
                "sessionId": session_id,
                "transport": media_transport,
            }
        )
        self.on_state("正在可靠加入房间…")

    def send(self, body: dict) -> None:
        tcp_socket = self._socket
        if tcp_socket is None:
            return
        data = (
            json.dumps(body, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        with self._send_lock:
            tcp_socket.sendall(data)

    def stop(self) -> None:
        if self._socket is not None and self._running.is_set():
            try:
                self.send({"action": "leave"})
            except OSError:
                pass
        self._running.clear()
        if self._socket is not None:
            try:
                self._socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._socket.close()
        self._socket = None

    def _receive_loop(self) -> None:
        buffer = bytearray()
        last_heartbeat = time.monotonic()
        while self._running.is_set():
            tcp_socket = self._socket
            if tcp_socket is None:
                return
            try:
                chunk = tcp_socket.recv(4096)
                if not chunk:
                    self.on_state("服务器关闭了信令连接")
                    return
                buffer.extend(chunk)
                while b"\n" in buffer:
                    line, _, remainder = buffer.partition(b"\n")
                    buffer = bytearray(remainder)
                    if line:
                        body = json.loads(line.decode("utf-8"))
                        if isinstance(body, dict):
                            self.on_control(body)
            except socket.timeout:
                pass
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                if self._running.is_set():
                    self.on_state(f"信令错误：{exc}")
                return

            now = time.monotonic()
            if now - last_heartbeat >= 5:
                try:
                    self.send({"action": "heartbeat"})
                except OSError as exc:
                    self.on_state(f"信令心跳失败：{exc}")
                    return
                last_heartbeat = now
