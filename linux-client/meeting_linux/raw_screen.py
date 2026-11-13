from __future__ import annotations

from collections.abc import Callable

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


class RawScreenShareController:
    """Captures I420 frames. WebRTC owns encoding, pacing and retransmission."""

    def __init__(
        self,
        on_frame: Callable[[bytes, int, int, int], None],
        on_error: Callable[[str], None],
    ) -> None:
        self._on_frame = on_frame
        self._on_error = on_error
        self._pipeline: Gst.Pipeline | None = None
        self._fallback_timestamp_us = 0

    def start(self) -> None:
        if self._pipeline is not None:
            return
        pipeline = Gst.parse_launch(
            "ximagesrc use-damage=false show-pointer=true "
            "! videorate ! video/x-raw,framerate=30/1 "
            "! videoscale add-borders=true "
            "! video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1 "
            "! videoconvert ! video/x-raw,format=I420 "
            "! appsink name=sink emit-signals=true max-buffers=2 "
            "drop=true sync=false"
        )
        sink = pipeline.get_by_name("sink")
        sink.connect("new-sample", self._new_sample)
        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_bus_message)
        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            pipeline.set_state(Gst.State.NULL)
            raise RuntimeError("GStreamer 无法启动屏幕原始帧采集")
        self._pipeline = pipeline

    def stop(self) -> None:
        if self._pipeline is None:
            return
        self._pipeline.set_state(Gst.State.NULL)
        self._pipeline = None

    def _new_sample(self, sink: Gst.Element) -> Gst.FlowReturn:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.ERROR
        caps = sample.get_caps().get_structure(0)
        width = caps.get_value("width")
        height = caps.get_value("height")
        buffer = sample.get_buffer()
        i420 = buffer.extract_dup(0, buffer.get_size())
        if buffer.pts != Gst.CLOCK_TIME_NONE:
            timestamp_us = int(buffer.pts // Gst.MSECOND * 1000)
        else:
            timestamp_us = self._fallback_timestamp_us
        self._fallback_timestamp_us = timestamp_us + 33_333
        self._on_frame(i420, width, height, timestamp_us)
        return Gst.FlowReturn.OK

    def _on_bus_message(self, _bus: Gst.Bus, message: Gst.Message) -> None:
        if message.type == Gst.MessageType.ERROR:
            error, _debug = message.parse_error()
            self._on_error(f"屏幕采集错误：{error.message}")
