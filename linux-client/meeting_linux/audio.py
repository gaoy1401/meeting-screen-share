from __future__ import annotations

from collections.abc import Callable

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


class AudioController:
    def __init__(
        self,
        on_captured: Callable[[bytes, int], None],
        on_error: Callable[[str], None],
    ) -> None:
        self._on_captured = on_captured
        self._on_error = on_error
        self._capture: Gst.Pipeline | None = None
        self._fallback_timestamp = 0
        self._playback = Gst.parse_launch(
            "appsrc name=source is-live=true format=time do-timestamp=true "
            "caps=audio/x-opus,rate=48000,channels=1,channel-mapping-family=0 "
            "! queue max-size-time=250000000 leaky=downstream "
            "! opusparse ! opusdec plc=true use-inband-fec=true "
            "! audioconvert ! audioresample ! autoaudiosink sync=false"
        )
        self._source = self._playback.get_by_name("source")
        self._watch_bus(self._playback, "扬声器")
        self._playback.set_state(Gst.State.PLAYING)

    def start_microphone(self) -> None:
        if self._capture is not None:
            return
        if Gst.ElementFactory.find("opusenc") is None:
            raise RuntimeError("缺少 GStreamer opusenc 插件")
        pipeline = Gst.parse_launch(
            "autoaudiosrc ! audioconvert ! audioresample "
            "! audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved "
            "! opusenc bitrate=24000 frame-size=20 audio-type=voice "
            "inband-fec=true packet-loss-percentage=10 "
            "! appsink name=sink emit-signals=true max-buffers=8 drop=true sync=false"
        )
        sink = pipeline.get_by_name("sink")
        sink.connect("new-sample", self._new_audio_sample)
        self._watch_bus(pipeline, "麦克风")
        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            pipeline.set_state(Gst.State.NULL)
            raise RuntimeError("GStreamer 无法启动 Opus 麦克风")
        self._capture = pipeline

    def stop_microphone(self) -> None:
        if self._capture is None:
            return
        self._capture.set_state(Gst.State.NULL)
        self._capture = None

    def play_opus(self, _ssrc: int, opus: bytes) -> None:
        if not opus:
            return
        buffer = Gst.Buffer.new_allocate(None, len(opus), None)
        buffer.fill(0, opus)
        buffer.duration = 20 * Gst.MSECOND
        self._source.emit("push-buffer", buffer)

    def stop(self) -> None:
        self.stop_microphone()
        self._playback.set_state(Gst.State.NULL)

    def _new_audio_sample(self, sink: Gst.Element) -> Gst.FlowReturn:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.ERROR
        buffer = sample.get_buffer()
        opus = buffer.extract_dup(0, buffer.get_size())
        if buffer.pts != Gst.CLOCK_TIME_NONE:
            timestamp = int(buffer.pts * 48_000 // Gst.SECOND) & 0xFFFFFFFF
        else:
            timestamp = self._fallback_timestamp
        self._fallback_timestamp = (timestamp + 960) & 0xFFFFFFFF
        self._on_captured(opus, timestamp)
        return Gst.FlowReturn.OK

    def _watch_bus(self, pipeline: Gst.Pipeline, label: str) -> None:
        bus = pipeline.get_bus()
        bus.add_signal_watch()

        def on_message(_bus: Gst.Bus, message: Gst.Message) -> None:
            if message.type == Gst.MessageType.ERROR:
                error, _debug = message.parse_error()
                self._on_error(f"{label}错误：{error.message}")

        bus.connect("message", on_message)
