from meeting_linux.hardware_screen import (
    HardwareScreenConfig,
    parse_livekit_credentials,
    tcp_port_is_listening,
)


key, secret = parse_livekit_credentials(
    """
port: 7880
keys:
  test-key: "test secret"
logging:
  level: info
"""
)
assert key == "test-key"
assert secret == "test secret"

for header in ("keys: # API credentials", "keys:\t# API credentials"):
    assert parse_livekit_credentials(
        f"{header}\n  test-key: test-secret\n"
    ) == ("test-key", "test-secret")

config = HardwareScreenConfig()
gst = config.gstreamer_command()
lk = config.livekit_command("/home/test/.local/bin/lk")
assert "nvh264enc" in gst
assert "bitrate=6000" in gst
assert "gop-size=30" in gst
assert "video/x-raw,framerate=30/1" in gst
assert "video/x-raw,width=1920,height=1080,format=BGRA" in " ".join(gst)
assert "h264://127.0.0.1:5005" in lk
assert "--metadata" in lk
assert "pxg-screen" in lk
assert not tcp_port_is_listening(1)

print("Linux NVENC screen publisher checks passed")
