from __future__ import annotations

from collections.abc import Callable

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


class H264Decoder:
    def __init__(
        self,
        on_frame: Callable[[bytes, int, int, int], None],
        on_error: Callable[[str], None],
    ) -> None:
        self._on_frame = on_frame
        self._on_error = on_error
        self._pipeline = Gst.parse_launch(
            "appsrc name=source is-live=true format=time "
            "caps=video/x-h264,stream-format=byte-stream,alignment=au "
            "! queue max-size-buffers=3 leaky=downstream "
            "! h264parse ! decodebin ! videoconvert "
            "! video/x-raw,format=RGB "
            "! appsink name=sink emit-signals=true max-buffers=2 drop=true sync=false"
        )
        self._source = self._pipeline.get_by_name("source")
        sink = self._pipeline.get_by_name("sink")
        sink.connect("new-sample", self._new_sample)
        bus = self._pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_bus_message)
        result = self._pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("GStreamer 无法启动 H.264 解码器")

    def decode(self, access_unit: bytes, timestamp: int) -> None:
        if not access_unit:
            return
        buffer = Gst.Buffer.new_allocate(None, len(access_unit), None)
        buffer.fill(0, access_unit)
        buffer.pts = int(timestamp) * Gst.SECOND // 90_000
        buffer.duration = Gst.SECOND // 30
        self._source.emit("push-buffer", buffer)

    def stop(self) -> None:
        self._pipeline.set_state(Gst.State.NULL)

    def _new_sample(self, sink: Gst.Element) -> Gst.FlowReturn:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.ERROR
        caps = sample.get_caps()
        structure = caps.get_structure(0)
        width = structure.get_value("width")
        height = structure.get_value("height")
        buffer = sample.get_buffer()
        rgb = buffer.extract_dup(0, buffer.get_size())
        if not width or not height or len(rgb) < width * height * 3:
            return Gst.FlowReturn.ERROR
        row_stride = len(rgb) // height
        self._on_frame(rgb, width, height, row_stride)
        return Gst.FlowReturn.OK

    def _on_bus_message(self, _bus: Gst.Bus, message: Gst.Message) -> None:
        if message.type == Gst.MessageType.ERROR:
            error, _debug = message.parse_error()
            self._on_error(f"H.264 解码错误：{error.message}")
