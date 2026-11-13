from __future__ import annotations

import ast
import json
import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


def tcp_port_is_listening(port: int) -> bool:
    """Check Linux TCP listen tables without consuming a publisher connection."""
    expected_port = f"{port:04X}"
    for table_path in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        try:
            lines = table_path.read_text(encoding="ascii").splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) < 4:
                continue
            local_address = fields[1]
            state = fields[3]
            if (
                local_address.rpartition(":")[2].upper() == expected_port
                and state == "0A"
            ):
                return True
    return False


def _yaml_scalar(value: str) -> str:
    value = value.strip()
    if value.startswith(("'", '"')):
        parsed = ast.literal_eval(value)
        if not isinstance(parsed, str):
            raise ValueError("LiveKit credential must be a string")
        return parsed
    return value.split(" #", 1)[0].strip()


def parse_livekit_credentials(config_text: str) -> tuple[str, str]:
    """Read the first API key pair from the small LiveKit LAN YAML config."""
    keys_indent: int | None = None
    for raw_line in config_text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip())
        if keys_indent is None:
            header = stripped.split(maxsplit=1)
            if header[0] == "keys:" and (
                len(header) == 1 or header[1].startswith("#")
            ):
                keys_indent = indent
            continue
        if indent <= keys_indent:
            break
        key, separator, value = stripped.partition(":")
        if separator and key.strip() and value.strip():
            return _yaml_scalar(key), _yaml_scalar(value)
    raise ValueError("LiveKit config contains no API key pair")


def load_livekit_credentials(config_path: Path) -> tuple[str, str]:
    api_key = os.environ.get("LIVEKIT_API_KEY")
    api_secret = os.environ.get("LIVEKIT_API_SECRET")
    if api_key and api_secret:
        return api_key, api_secret
    return parse_livekit_credentials(config_path.read_text(encoding="utf-8"))


@dataclass(frozen=True)
class HardwareScreenConfig:
    width: int = 1920
    height: int = 1080
    frames_per_second: int = 30
    bitrate_kbps: int = 6000
    keyframe_interval: int = 30
    tcp_port: int = 5005
    room: str = "demo"
    identity: str = "pxg-screen"
    livekit_url: str = "ws://127.0.0.1:7880"
    display: str = ":0"
    xauthority: str = ""

    @classmethod
    def from_environment(cls) -> HardwareScreenConfig:
        config = cls(
            width=int(os.environ.get("MEETING_SCREEN_WIDTH", "1920")),
            height=int(os.environ.get("MEETING_SCREEN_HEIGHT", "1080")),
            frames_per_second=int(
                os.environ.get("MEETING_SCREEN_FPS", "30")
            ),
            bitrate_kbps=int(
                os.environ.get("MEETING_SCREEN_BITRATE_KBPS", "6000")
            ),
            keyframe_interval=int(
                os.environ.get("MEETING_SCREEN_GOP", "30")
            ),
            tcp_port=int(os.environ.get("MEETING_SCREEN_TCP_PORT", "5005")),
            room=os.environ.get("MEETING_ROOM", "demo"),
            identity=os.environ.get(
                "MEETING_AUX_SCREEN_IDENTITY",
                "pxg-screen",
            ),
            livekit_url=os.environ.get(
                "MEETING_LIVEKIT_URL",
                "ws://127.0.0.1:7880",
            ),
            display=os.environ.get("DISPLAY", ":0"),
            xauthority=os.environ.get(
                "XAUTHORITY",
                "",
            ),
        )
        config.validate()
        return config

    def validate(self) -> None:
        if self.width <= 0 or self.height <= 0:
            raise ValueError("screen dimensions must be positive")
        if self.width % 2 or self.height % 2:
            raise ValueError("screen dimensions must be even")
        if not 1 <= self.frames_per_second <= 60:
            raise ValueError("screen frame rate must be between 1 and 60")
        if not 100 <= self.bitrate_kbps <= 100_000:
            raise ValueError("screen bitrate is outside the supported range")
        if self.keyframe_interval <= 0:
            raise ValueError("keyframe interval must be positive")
        if not 1 <= self.tcp_port <= 65535:
            raise ValueError("screen TCP port is invalid")
        if not self.room or not self.identity:
            raise ValueError("room and screen identity are required")

    def gstreamer_command(self) -> list[str]:
        return [
            "gst-launch-1.0",
            "-e",
            "ximagesrc",
            "use-damage=true",
            "show-pointer=true",
            "!",
            "videorate",
            "!",
            f"video/x-raw,framerate={self.frames_per_second}/1",
            "!",
            "videoscale",
            "add-borders=true",
            "!",
            "videoconvert",
            "!",
            (
                "video/x-raw,"
                f"width={self.width},height={self.height},"
                "format=BGRA,pixel-aspect-ratio=1/1"
            ),
            "!",
            "queue",
            "max-size-buffers=2",
            "leaky=downstream",
            "!",
            "nvh264enc",
            f"bitrate={self.bitrate_kbps}",
            f"gop-size={self.keyframe_interval}",
            "preset=low-latency-hq",
            "rc-mode=cbr-ld-hq",
            "bframes=0",
            "zerolatency=true",
            "aud=true",
            "!",
            "h264parse",
            "config-interval=-1",
            "disable-passthrough=true",
            "!",
            (
                "video/x-h264,stream-format=byte-stream,"
                "alignment=au,profile=baseline"
            ),
            "!",
            "tcpserversink",
            "host=127.0.0.1",
            f"port={self.tcp_port}",
            "sync=false",
            "async=false",
        ]

    def livekit_command(self, lk_path: str) -> list[str]:
        metadata = json.dumps(
            {"auxiliary": "screen", "owner": "PXG"},
            separators=(",", ":"),
        )
        return [
            lk_path,
            "--url",
            self.livekit_url,
            "room",
            "join",
            "--identity",
            self.identity,
            "--metadata",
            metadata,
            "--publish",
            f"h264://127.0.0.1:{self.tcp_port}",
            "--fps",
            str(self.frames_per_second),
            "--h26x-streaming-format",
            "annex-b",
            self.room,
        ]


class HardwareScreenPublisher:
    def __init__(
        self,
        config: HardwareScreenConfig,
        api_key: str,
        api_secret: str,
    ) -> None:
        self.config = config
        self.api_key = api_key
        self.api_secret = api_secret
        self._stopping = False
        self._children: list[subprocess.Popen[bytes]] = []

    def stop(self, _signal: int | None = None, _frame: object = None) -> None:
        self._stopping = True
        for child in reversed(self._children):
            if child.poll() is None:
                child.terminate()

    def run(self) -> int:
        gst_path = shutil.which("gst-launch-1.0")
        lk_path = shutil.which("lk")
        if not lk_path:
            user_lk = Path.home() / ".local/bin/lk"
            if user_lk.is_file() and os.access(user_lk, os.X_OK):
                lk_path = str(user_lk)
        if not gst_path:
            raise RuntimeError("gst-launch-1.0 is not installed")
        if not lk_path:
            raise RuntimeError("LiveKit CLI 'lk' is not installed")
        if not shutil.which("gst-inspect-1.0"):
            raise RuntimeError("gst-inspect-1.0 is not installed")
        if subprocess.run(
            ["gst-inspect-1.0", "nvh264enc"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode:
            raise RuntimeError("GStreamer nvh264enc is unavailable")

        child_env = os.environ.copy()
        child_env["DISPLAY"] = self.config.display
        if self.config.xauthority:
            child_env["XAUTHORITY"] = self.config.xauthority
        child_env["LIVEKIT_API_KEY"] = self.api_key
        child_env["LIVEKIT_API_SECRET"] = self.api_secret

        gst_command = self.config.gstreamer_command()
        gst_command[0] = gst_path
        print(
            "Starting NVENC screen capture: "
            f"{self.config.width}x{self.config.height} "
            f"{self.config.frames_per_second} FPS "
            f"{self.config.bitrate_kbps} kbps",
            flush=True,
        )
        try:
            gst_process = subprocess.Popen(gst_command, env=child_env)
            self._children.append(gst_process)
            listen_deadline = time.monotonic() + 15
            while not tcp_port_is_listening(self.config.tcp_port):
                if self._stopping:
                    return 0
                return_code = gst_process.poll()
                if return_code is not None:
                    return return_code or 1
                if time.monotonic() >= listen_deadline:
                    raise RuntimeError(
                        "GStreamer did not open its H264 TCP port within 15 seconds"
                    )
                time.sleep(0.1)

            livekit_command = self.config.livekit_command(lk_path)
            print(
                "Publishing hardware H264 track: "
                f"room={self.config.room} identity={self.config.identity}",
                flush=True,
            )
            livekit_process = subprocess.Popen(livekit_command, env=child_env)
            self._children.append(livekit_process)

            while not self._stopping:
                for child in self._children:
                    return_code = child.poll()
                    if return_code is not None:
                        return return_code or 1
                time.sleep(0.25)
            return 0
        finally:
            self.stop()
            for child in reversed(self._children):
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)


def main() -> int:
    config = HardwareScreenConfig.from_environment()
    config_path = Path(
        os.environ.get(
            "MEETING_LIVEKIT_CONFIG",
            str(Path(__file__).resolve().parents[2] / ".runtime/server/livekit.yaml"),
        )
    ).expanduser()
    api_key, api_secret = load_livekit_credentials(config_path)
    publisher = HardwareScreenPublisher(config, api_key, api_secret)
    signal.signal(signal.SIGINT, publisher.stop)
    signal.signal(signal.SIGTERM, publisher.stop)
    return publisher.run()


if __name__ == "__main__":
    raise SystemExit(main())
