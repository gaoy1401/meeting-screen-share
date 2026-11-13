from __future__ import annotations

import os
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from livekit import rtc


@dataclass(frozen=True)
class VideoCodecPolicy:
    """Keeps codec selection out of the transport and UI modules."""

    requested_name: str

    @classmethod
    def from_environment(cls) -> "VideoCodecPolicy":
        raw = os.environ.get("MEETING_VIDEO_CODEC", "h264").strip().lower()
        return cls("h265" if raw in {"h265", "hevc"} else "h264")

    @property
    def requested_codec(self) -> rtc.VideoCodec:
        from livekit import rtc

        return (
            rtc.VideoCodec.H265
            if self.requested_name == "h265"
            else rtc.VideoCodec.H264
        )

    @property
    def allows_h264_fallback(self) -> bool:
        return self.requested_name == "h265"
