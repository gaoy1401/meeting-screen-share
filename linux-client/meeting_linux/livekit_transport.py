from __future__ import annotations

import asyncio
import threading
from collections.abc import Callable
from concurrent.futures import Future

from livekit import rtc

from .media_policy import VideoCodecPolicy

AUXILIARY_SCREEN_IDENTITY = "pxg-screen"


class LiveKitMeetingTransport:
    """WebRTC media adapter. GTK and TCP signaling stay outside this module."""

    def __init__(self) -> None:
        self.on_state: Callable[[str], None] = lambda _message: None
        self.on_joined: Callable[[], None] = lambda: None
        self.on_participant_count: Callable[[int], None] = lambda _count: None
        self.on_video: Callable[[bytes, int, int, int], None] = (
            lambda _rgb, _width, _height, _stride: None
        )

        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(
            target=self._run_loop,
            name="meeting-livekit",
            daemon=True,
        )
        self._thread.start()
        self._room: rtc.Room | None = None
        self._platform_audio: rtc.PlatformAudio | None = None
        self._microphone_source: rtc.PlatformAudioSource | None = None
        self._microphone_track: rtc.LocalAudioTrack | None = None
        self._microphone_publication: rtc.LocalTrackPublication | None = None
        self._screen_source: rtc.VideoSource | None = None
        self._screen_track: rtc.LocalVideoTrack | None = None
        self._screen_publication: rtc.LocalTrackPublication | None = None
        self._video_tasks: set[asyncio.Task] = set()
        self._video_codec_policy = VideoCodecPolicy.from_environment()

    def start(self, url: str, token: str) -> Future:
        return self._submit(self._connect(url, token))

    def stop(self) -> Future:
        return self._submit(self._disconnect())

    def close(self) -> None:
        try:
            self.stop().result(timeout=5)
        except Exception:
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2)

    def set_microphone(self, enabled: bool) -> Future:
        return self._submit(self._set_microphone(enabled))

    def set_screen_share(self, enabled: bool) -> Future:
        return self._submit(self._set_screen_share(enabled))

    def capture_screen_frame(
        self,
        i420: bytes,
        width: int,
        height: int,
        timestamp_us: int,
    ) -> None:
        def capture() -> None:
            source = self._screen_source
            if source is None:
                return
            source.capture_frame(
                rtc.VideoFrame(
                    width,
                    height,
                    rtc.VideoBufferType.I420,
                    i420,
                ),
                timestamp_us=timestamp_us,
            )

        self._loop.call_soon_threadsafe(capture)

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _submit(self, coroutine: object) -> Future:
        return asyncio.run_coroutine_threadsafe(coroutine, self._loop)

    async def _connect(self, url: str, token: str) -> None:
        await self._disconnect()
        self.on_state("正在连接 WebRTC SFU…")
        room = rtc.Room(loop=self._loop)
        self._room = room

        room.on("participant_connected", lambda _participant: self._emit_count())
        room.on("participant_disconnected", lambda _participant: self._emit_count())
        room.on("room_updated", self._emit_count)
        room.on("reconnecting", lambda: self.on_state("网络波动，WebRTC 正在重连…"))
        room.on("reconnected", lambda: self.on_state("WebRTC 已恢复连接"))
        room.on(
            "disconnected",
            lambda _reason: self.on_state("WebRTC 已断开"),
        )

        @room.on("track_subscribed")
        def on_track_subscribed(
            track: rtc.Track,
            publication: rtc.RemoteTrackPublication,
            _participant: rtc.RemoteParticipant,
        ) -> None:
            if (
                publication.source == rtc.TrackSource.SOURCE_SCREENSHARE
                and isinstance(track, rtc.RemoteVideoTrack)
            ):
                task = self._loop.create_task(self._consume_video(track))
                self._video_tasks.add(task)
                task.add_done_callback(self._video_tasks.discard)

        try:
            self._platform_audio = rtc.PlatformAudio()
        except Exception as exc:
            self._platform_audio = None
            self.on_state(f"音频设备不可用，仍可入会：{exc}")

        try:
            await room.connect(url, token)
        except Exception:
            await self._disconnect()
            raise

        self._emit_count()
        self.on_joined()

    async def _disconnect(self) -> None:
        await self._set_screen_share(False)
        if self._microphone_publication is not None and self._room is not None:
            try:
                await self._room.local_participant.unpublish_track(
                    self._microphone_publication.sid
                )
            except Exception:
                pass
        self._microphone_publication = None
        self._microphone_track = None
        if self._microphone_source is not None:
            self._microphone_source.close()
            self._microphone_source = None

        for task in list(self._video_tasks):
            task.cancel()
        if self._video_tasks:
            await asyncio.gather(*self._video_tasks, return_exceptions=True)
        self._video_tasks.clear()

        room = self._room
        self._room = None
        if room is not None and room.isconnected():
            try:
                await room.disconnect()
            except Exception:
                pass
        if self._platform_audio is not None:
            self._platform_audio.close()
            self._platform_audio = None
        self.on_participant_count(0)

    async def _set_microphone(self, enabled: bool) -> None:
        room = self._require_room()
        if not enabled:
            if self._microphone_track is not None:
                self._microphone_track.mute()
            return
        if self._microphone_track is not None:
            self._microphone_track.unmute()
            return
        if self._platform_audio is None:
            raise RuntimeError("PXG 没有可用的系统音频设备")

        source = self._platform_audio.create_audio_source(
            rtc.PlatformAudioOptions(
                echo_cancellation=True,
                noise_suppression=True,
                auto_gain_control=True,
            )
        )
        track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
        options = rtc.TrackPublishOptions(
            source=rtc.TrackSource.SOURCE_MICROPHONE,
            dtx=True,
            red=True,
        )
        try:
            publication = await room.local_participant.publish_track(track, options)
        except Exception:
            source.close()
            raise
        self._microphone_source = source
        self._microphone_track = track
        self._microphone_publication = publication

    async def _set_screen_share(self, enabled: bool) -> None:
        room = self._room
        if not enabled:
            if self._screen_publication is not None and room is not None:
                try:
                    await room.local_participant.unpublish_track(
                        self._screen_publication.sid
                    )
                except Exception:
                    pass
            self._screen_publication = None
            self._screen_track = None
            if self._screen_source is not None:
                await self._screen_source.aclose()
                self._screen_source = None
            return

        room = self._require_room()
        if self._screen_publication is not None:
            return
        source = rtc.VideoSource(1920, 1080, is_screencast=True)
        track = rtc.LocalVideoTrack.create_video_track("screen_share", source)
        options = self._screen_publish_options(
            self._video_codec_policy.requested_codec
        )
        try:
            publication = await room.local_participant.publish_track(track, options)
            self.on_state(
                f"屏幕共享编码：{self._video_codec_policy.requested_name.upper()}"
            )
        except Exception as primary_error:
            if not self._video_codec_policy.allows_h264_fallback:
                await source.aclose()
                raise
            self.on_state(f"HEVC 发布失败，正在回落 H264：{primary_error}")
            try:
                publication = await room.local_participant.publish_track(
                    track,
                    self._screen_publish_options(rtc.VideoCodec.H264),
                )
            except Exception:
                await source.aclose()
                raise
            self.on_state("屏幕共享编码：H264（HEVC 不可用，已自动回落）")
        self._screen_source = source
        self._screen_track = track
        self._screen_publication = publication

    @staticmethod
    def _screen_publish_options(
        codec: rtc.VideoCodec,
    ) -> rtc.TrackPublishOptions:
        return rtc.TrackPublishOptions(
            source=rtc.TrackSource.SOURCE_SCREENSHARE,
            video_codec=codec,
            simulcast=False,
            degradation_preference=rtc.DegradationPreference.MAINTAIN_RESOLUTION,
            video_encoding=rtc.VideoEncoding(
                max_bitrate=6_000_000,
                max_framerate=30,
            ),
        )

    async def _consume_video(self, track: rtc.RemoteVideoTrack) -> None:
        stream = rtc.VideoStream(
            track,
            loop=self._loop,
            capacity=2,
            format=rtc.VideoBufferType.RGB24,
        )
        try:
            async for event in stream:
                frame = event.frame
                self.on_video(
                    bytes(frame.data),
                    frame.width,
                    frame.height,
                    frame.width * 3,
                )
        finally:
            await stream.aclose()

    def _require_room(self) -> rtc.Room:
        if self._room is None or not self._room.isconnected():
            raise RuntimeError("尚未连接 WebRTC 房间")
        return self._room

    def _emit_count(self) -> None:
        room = self._room
        if room is None:
            count = 0
        else:
            count = 1 + sum(
                participant.identity != AUXILIARY_SCREEN_IDENTITY
                for participant in room.remote_participants.values()
            )
        self.on_participant_count(count)
