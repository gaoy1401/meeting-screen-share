from __future__ import annotations

import re
import socket
import sys
import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gst", "1.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gst, Gtk  # noqa: E402

from .audio import AudioController
from .jitter import AudioJitterBuffer
from .livekit_transport import LiveKitMeetingTransport
from .raw_screen import RawScreenShareController
from .rtp import H264Depacketizer
from .screen import ScreenShareController
from .signaling import SignalingTransport
from .transport import MeetingTransport
from .video_decoder import H264Decoder

ROOM_PATTERN = re.compile(r"^[A-Za-z0-9_-]{2,64}$")


class MeetingWindow(Gtk.ApplicationWindow):
    def __init__(self, application: Gtk.Application) -> None:
        self.media_transport = (
            "udp"
            if os.environ.get("MEETING_MEDIA_TRANSPORT", "webrtc").lower() == "udp"
            else "webrtc"
        )
        title = (
            "Meeting UDP · Linux"
            if self.media_transport == "udp"
            else "Meeting WebRTC · Linux"
        )
        super().__init__(application=application, title=title)
        self.set_default_size(980, 720)
        self.transport = MeetingTransport()
        self.signaling = SignalingTransport()
        self.h264_depacketizer = H264Depacketizer()
        self.joined = False
        self.auto_microphone = os.environ.get("MEETING_AUTO_MIC") == "1"
        self.auto_screen = os.environ.get("MEETING_AUTO_SHARE") == "1"
        self.external_screen = os.environ.get("MEETING_EXTERNAL_SCREEN") == "1"
        self.pending_endpoint: tuple[str, int] | None = None
        self.pending_room = ""
        self.pending_name = ""

        self.audio: AudioController | None = None
        self.audio_jitter: AudioJitterBuffer | None = None
        self.video_decoder: H264Decoder | None = None
        self.screen: ScreenShareController | None = None
        self.livekit: LiveKitMeetingTransport | None = None
        self.raw_screen: RawScreenShareController | None = None

        if self.media_transport == "udp":
            self.audio = AudioController(
                self.transport.send_audio,
                lambda message: GLib.idle_add(self._set_status, message),
            )
            self.audio_jitter = AudioJitterBuffer(self.audio.play_opus)
            self.video_decoder = H264Decoder(
                lambda rgb, width, height, stride: GLib.idle_add(
                    self._show_rgb,
                    rgb,
                    width,
                    height,
                    stride,
                ),
                lambda message: GLib.idle_add(self._set_status, message),
            )
            self.screen = ScreenShareController(
                self.transport.send_screen,
                lambda message: GLib.idle_add(self._screen_failed, message),
            )
            self.transport.on_state = lambda message: GLib.idle_add(
                self._set_status, message
            )
            self.transport.on_control = lambda body: GLib.idle_add(
                self._handle_udp_control, body
            )
            self.transport.on_audio = self.audio_jitter.ingest
            self.transport.on_screen = self._handle_screen_packet
        else:
            self.livekit = LiveKitMeetingTransport()
            self.livekit.on_state = lambda message: GLib.idle_add(
                self._set_status, message
            )
            self.livekit.on_joined = lambda: GLib.idle_add(
                self._web_rtc_joined
            )
            self.livekit.on_participant_count = lambda count: GLib.idle_add(
                self._set_participant_count,
                count,
            )
            self.livekit.on_video = lambda rgb, width, height, stride: GLib.idle_add(
                self._show_rgb,
                rgb,
                width,
                height,
                stride,
            )
            self.raw_screen = RawScreenShareController(
                self.livekit.capture_screen_frame,
                lambda message: GLib.idle_add(self._screen_failed, message),
            )
        self.signaling.on_state = lambda message: GLib.idle_add(
            self._set_status, message
        )
        self.signaling.on_control = lambda body: GLib.idle_add(
            self._handle_control, body
        )

        self._build_ui()
        self.connect("close-request", self._close)
        if os.environ.get("MEETING_AUTO_JOIN") == "1":
            GLib.idle_add(self._toggle_join, self.join_button)

    def _build_ui(self) -> None:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.set_margin_top(16)
        root.set_margin_bottom(16)
        root.set_margin_start(16)
        root.set_margin_end(16)
        self.set_child(root)

        connection = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        root.append(connection)
        self.server_entry = self._entry(
            os.environ.get("MEETING_SERVER", "127.0.0.1:9000"), 220
        )
        self.room_entry = self._entry(os.environ.get("MEETING_ROOM", "demo"), 120)
        self.name_entry = self._entry(
            os.environ.get("MEETING_NAME", f"PXG-{socket.gethostname()}"), 220
        )
        for label, entry in (
            ("服务器", self.server_entry),
            ("房间号", self.room_entry),
            ("昵称", self.name_entry),
        ):
            group = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            group.append(Gtk.Label(label=label, xalign=0))
            group.append(entry)
            connection.append(group)
        self.join_button = Gtk.Button(label="加入会议")
        self.join_button.connect("clicked", self._toggle_join)
        connection.append(self.join_button)

        state_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.count_label = Gtk.Label(label="0 人在线", xalign=0)
        self.status_label = Gtk.Label(label="尚未连接", xalign=1)
        self.status_label.set_hexpand(True)
        state_row.append(self.count_label)
        state_row.append(self.status_label)
        root.append(state_row)

        media_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=20)
        self.mic_switch = Gtk.Switch()
        self.mic_switch.set_sensitive(False)
        self.mic_switch.connect("notify::active", self._toggle_microphone)
        self.share_switch = Gtk.Switch()
        self.share_switch.set_sensitive(False)
        self.share_switch.connect("notify::active", self._toggle_screen)
        media_row.append(Gtk.Label(label="麦克风"))
        media_row.append(self.mic_switch)
        media_row.append(Gtk.Label(label="共享屏幕"))
        media_row.append(self.share_switch)
        root.append(media_row)

        self.picture = Gtk.Picture()
        self.picture.set_hexpand(True)
        self.picture.set_vexpand(True)
        self.picture.set_can_shrink(True)
        self.picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        root.append(self.picture)

    @staticmethod
    def _entry(value: str, width: int) -> Gtk.Entry:
        entry = Gtk.Entry()
        entry.set_text(value)
        entry.set_size_request(width, -1)
        return entry

    def _toggle_join(self, _button: Gtk.Button) -> None:
        if self.joined:
            self._leave()
            return
        endpoint = self.server_entry.get_text().strip()
        try:
            host, port_text = endpoint.rsplit(":", 1)
            port = int(port_text)
            if not host or not 1 <= port <= 65535:
                raise ValueError
        except ValueError:
            self._set_status("服务器地址应为 主机:端口")
            return
        room = self.room_entry.get_text().strip()
        name = self.name_entry.get_text().strip()
        if not ROOM_PATTERN.fullmatch(room):
            self._set_status("房间号格式不正确")
            return
        if not name:
            self._set_status("请输入昵称")
            return
        try:
            self.pending_endpoint = (host, port)
            self.pending_room = room
            self.pending_name = name[:32]
            self.signaling.start(
                host,
                port,
                room,
                self.pending_name,
                self.transport.session_id,
                self.media_transport,
            )
        except OSError as exc:
            self._set_status(f"连接失败：{exc}")

    def _handle_control(self, body: dict) -> bool:
        action = body.get("action")
        if action == "webrtc_connect":
            if self.livekit is None:
                return GLib.SOURCE_REMOVE
            url = body.get("url")
            token = body.get("token")
            if not isinstance(url, str) or not isinstance(token, str):
                self._set_status("服务器返回的 WebRTC 凭据无效")
                return GLib.SOURCE_REMOVE
            future = self.livekit.start(url, token)
            future.add_done_callback(
                lambda result: GLib.idle_add(self._web_rtc_connect_finished, result)
            )
        elif action == "udp_bind":
            if self.media_transport != "udp":
                return GLib.SOURCE_REMOVE
            if self.pending_endpoint is None:
                return GLib.SOURCE_REMOVE
            token = body.get("token")
            if not isinstance(token, str):
                return GLib.SOURCE_REMOVE
            host, port = self.pending_endpoint
            self.transport.start(
                host,
                port,
                self.pending_room,
                self.pending_name,
                token,
            )
            self._set_status("正在绑定 UDP 媒体通道…")
        elif action == "joined":
            self._mark_joined(
                f"已加入房间 {body.get('room', '')}，媒体使用 UDP"
            )
        elif action == "snapshot":
            participants = body.get("participants", [])
            self.count_label.set_label(f"{len(participants)} 人在线")
        elif action == "error":
            self._set_status(f"服务器拒绝：{body.get('message', '未知错误')}")
        return GLib.SOURCE_REMOVE

    def _handle_udp_control(self, body: dict) -> bool:
        if body.get("action") == "error":
            message = body.get("message", "未知错误")
            if message == "not joined" and self.joined:
                self.joined = False
                self._set_status("UDP 会话已失效，正在自动重新加入…")
                if self.pending_endpoint is not None:
                    host, port = self.pending_endpoint
                    try:
                        self.signaling.start(
                            host,
                            port,
                            self.pending_room,
                            self.pending_name,
                            self.transport.session_id,
                            self.media_transport,
                        )
                    except OSError as exc:
                        self._set_status(f"自动重连失败：{exc}")
            else:
                self._set_status(f"UDP 绑定失败：{message}")
        return GLib.SOURCE_REMOVE

    def _toggle_microphone(self, switch: Gtk.Switch, _property: object) -> None:
        if self.livekit is not None:
            enabled = switch.get_active()
            future = self.livekit.set_microphone(enabled)
            future.add_done_callback(
                lambda result: GLib.idle_add(
                    self._microphone_change_finished,
                    enabled,
                    result,
                )
            )
            return
        try:
            if switch.get_active():
                assert self.audio is not None
                self.audio.start_microphone()
                self._set_status("麦克风已开启")
            else:
                assert self.audio is not None
                self.audio.stop_microphone()
        except Exception as exc:
            switch.set_active(False)
            self._set_status(f"麦克风启动失败：{exc}")

    def _toggle_screen(self, switch: Gtk.Switch, _property: object) -> None:
        if self.external_screen:
            return
        if self.livekit is not None:
            enabled = switch.get_active()
            if not enabled and self.raw_screen is not None:
                self.raw_screen.stop()
            future = self.livekit.set_screen_share(enabled)
            future.add_done_callback(
                lambda result: GLib.idle_add(
                    self._screen_change_finished,
                    enabled,
                    result,
                )
            )
            return
        try:
            if switch.get_active():
                assert self.screen is not None
                self.screen.start()
                self._set_status("正在共享屏幕")
            else:
                assert self.screen is not None
                self.screen.stop()
        except Exception as exc:
            switch.set_active(False)
            self._set_status(f"屏幕共享失败：{exc}")

    def _handle_screen_packet(self, packet: object) -> None:
        assert self.video_decoder is not None
        access_unit = self.h264_depacketizer.ingest(packet)
        if access_unit is not None:
            self.video_decoder.decode(access_unit, packet.timestamp)

    def _show_rgb(
        self,
        rgb: bytes,
        width: int,
        height: int,
        row_stride: int,
    ) -> bool:
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(
                GLib.Bytes.new(rgb),
                GdkPixbuf.Colorspace.RGB,
                False,
                8,
                width,
                height,
                row_stride,
            )
            self.picture.set_paintable(Gdk.Texture.new_for_pixbuf(pixbuf))
        except GLib.Error as exc:
            self._set_status(f"画面解码失败：{exc.message}")
        return GLib.SOURCE_REMOVE

    def _screen_failed(self, message: str) -> bool:
        if self.raw_screen is not None:
            self.raw_screen.stop()
        if self.livekit is not None:
            self.livekit.set_screen_share(False)
        self.share_switch.set_active(False)
        self._set_status(message)
        return GLib.SOURCE_REMOVE

    def _leave(self) -> None:
        self.mic_switch.set_active(False)
        self.share_switch.set_active(False)
        if self.livekit is not None:
            if self.raw_screen is not None:
                self.raw_screen.stop()
            self.livekit.stop()
        else:
            self.transport.stop()
        self.signaling.stop()
        self.h264_depacketizer.reset()
        if self.audio_jitter is not None:
            self.audio_jitter.reset()
        self.picture.set_paintable(None)
        self.joined = False
        self.join_button.set_label("加入会议")
        self._set_fields_sensitive(True)
        self.mic_switch.set_sensitive(False)
        self.share_switch.set_sensitive(False)
        self.count_label.set_label("0 人在线")
        self._set_status("已离开")

    def _set_fields_sensitive(self, value: bool) -> None:
        self.server_entry.set_sensitive(value)
        self.room_entry.set_sensitive(value)
        self.name_entry.set_sensitive(value)

    def _set_status(self, message: str) -> bool:
        self.status_label.set_label(message)
        return GLib.SOURCE_REMOVE

    def _set_participant_count(self, count: int) -> bool:
        self.count_label.set_label(f"{count} 人在线")
        return GLib.SOURCE_REMOVE

    def _mark_joined(self, message: str) -> bool:
        self.joined = True
        self.join_button.set_label("离开会议")
        self._set_fields_sensitive(False)
        self.mic_switch.set_sensitive(True)
        self.share_switch.set_sensitive(not self.external_screen)
        self._set_status(message)
        if self.auto_microphone:
            self.mic_switch.set_active(True)
        if self.external_screen:
            self.share_switch.set_active(True)
        elif self.auto_screen:
            self.share_switch.set_active(True)
        return GLib.SOURCE_REMOVE

    def _web_rtc_joined(self) -> bool:
        suffix = "，屏幕使用 NVIDIA H264" if self.external_screen else ""
        return self._mark_joined(
            f"已加入房间 {self.pending_room}，媒体使用 WebRTC/SRTP{suffix}"
        )

    def _web_rtc_connect_finished(self, future: object) -> bool:
        try:
            future.result()
        except Exception as exc:
            self._set_status(f"WebRTC 入会失败：{exc}")
        return GLib.SOURCE_REMOVE

    def _microphone_change_finished(
        self,
        enabled: bool,
        future: object,
    ) -> bool:
        try:
            future.result()
            if enabled:
                self._set_status("麦克风已开启，音频使用 WebRTC/Opus")
        except Exception as exc:
            if enabled:
                self.mic_switch.set_active(False)
            self._set_status(f"麦克风切换失败：{exc}")
        return GLib.SOURCE_REMOVE

    def _screen_change_finished(self, enabled: bool, future: object) -> bool:
        try:
            future.result()
            if enabled:
                assert self.raw_screen is not None
                self.raw_screen.start()
                self._set_status("正在通过 WebRTC 共享屏幕")
        except Exception as exc:
            if enabled:
                self.share_switch.set_active(False)
            self._set_status(f"屏幕共享失败：{exc}")
        return GLib.SOURCE_REMOVE

    def _close(self, _window: Gtk.Window) -> bool:
        self.signaling.stop()
        if self.livekit is not None:
            if self.raw_screen is not None:
                self.raw_screen.stop()
            self.livekit.close()
        else:
            self.transport.stop()
        if self.audio is not None:
            self.audio.stop()
        if self.audio_jitter is not None:
            self.audio_jitter.stop()
        if self.video_decoder is not None:
            self.video_decoder.stop()
        if self.screen is not None:
            self.screen.stop()
        return False


class MeetingApplication(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id="local.meeting.webrtc-linux")

    def do_activate(self) -> None:
        window = self.props.active_window
        if window is None:
            window = MeetingWindow(self)
        window.present()


def main() -> int:
    Gst.init(None)
    application = MeetingApplication()
    return application.run(sys.argv)
