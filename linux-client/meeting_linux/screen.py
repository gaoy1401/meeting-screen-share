from __future__ import annotations

from collections.abc import Callable

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import GLib, Gst, GstVideo  # noqa: E402

class ScreenShareController:
    def __init__(
        self,
        on_h264: Callable[[bytes, int], None],
        on_error: Callable[[str], None],
    ) -> None:
        self._on_h264 = on_h264
        self._on_error = on_error
        self._pipeline: Gst.Pipeline | None = None
        self._fallback_timestamp = 0
        self._keyframe_timer_id: int | None = None
        self._keyframe_count = 0

    def start(self) -> None:
        if self._pipeline is not None:
            return
        encoder = self._select_encoder()
        pipeline = Gst.parse_launch(
            "ximagesrc use-damage=false show-pointer=true "
            "! videorate ! video/x-raw,framerate=30/1 "
            "! videoscale add-borders=true "
            "! video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1 "
            "! videoconvert "
            f"! {encoder} name=encoder "
            "! h264parse config-interval=1 disable-passthrough=true "
            "! video/x-h264,stream-format=byte-stream,alignment=au "
            "! appsink name=sink emit-signals=true max-buffers=2 drop=true sync=false"
        )
        sink = pipeline.get_by_name("sink")
        sink.connect("new-sample", self._new_screen_sample)
        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_bus_message)
        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            pipeline.set_state(Gst.State.NULL)
            raise RuntimeError("GStreamer 无法启动 H.264 屏幕采集")
        self._pipeline = pipeline
        self._keyframe_timer_id = GLib.timeout_add_seconds(
            1,
            self._request_keyframe,
        )

    def stop(self) -> None:
        if self._keyframe_timer_id is not None:
            GLib.source_remove(self._keyframe_timer_id)
            self._keyframe_timer_id = None
        if self._pipeline is None:
            return
        self._pipeline.set_state(Gst.State.NULL)
        self._pipeline = None

    @staticmethod
    def _select_encoder() -> str:
        if Gst.ElementFactory.find("x264enc") is not None:
            return (
                "x264enc tune=zerolatency speed-preset=ultrafast "
                "bitrate=6000 key-int-max=30 byte-stream=true threads=4"
            )
        if Gst.ElementFactory.find("nvh264enc") is not None:
            return "nvh264enc bitrate=6000 gop-size=30 zerolatency=true"
        if Gst.ElementFactory.find("openh264enc") is not None:
            return "openh264enc bitrate=6000000 complexity=low gop-size=30"
        if Gst.ElementFactory.find("avenc_h264") is not None:
            return "avenc_h264 bitrate=6000000 gop-size=30"
        raise RuntimeError(
            "缺少 H.264 编码插件，需要 x264enc、openh264enc 或 nvh264enc"
        )

    def _new_screen_sample(self, sink: Gst.Element) -> Gst.FlowReturn:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.ERROR
        buffer = sample.get_buffer()
        access_unit = buffer.extract_dup(0, buffer.get_size())
        if buffer.pts != Gst.CLOCK_TIME_NONE:
            timestamp = int(buffer.pts * 90_000 // Gst.SECOND) & 0xFFFFFFFF
        else:
            timestamp = self._fallback_timestamp
        self._fallback_timestamp = (timestamp + 3_000) & 0xFFFFFFFF
        self._on_h264(access_unit, timestamp)
        return Gst.FlowReturn.OK

    def _request_keyframe(self) -> bool:
        if self._pipeline is None:
            self._keyframe_timer_id = None
            return GLib.SOURCE_REMOVE
        encoder = self._pipeline.get_by_name("encoder")
        if encoder is None:
            return GLib.SOURCE_CONTINUE
        event = GstVideo.video_event_new_upstream_force_key_unit(
            Gst.CLOCK_TIME_NONE,
            True,
            self._keyframe_count,
        )
        self._keyframe_count += 1
        source_pad = encoder.get_static_pad("src")
        if source_pad is not None:
            source_pad.send_event(event)
        return GLib.SOURCE_CONTINUE

    def _on_bus_message(self, _bus: Gst.Bus, message: Gst.Message) -> None:
        if message.type == Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            detail = f"（{debug}）" if debug else ""
            self._on_error(f"屏幕 H.264 编码错误：{error.message}{detail}")
