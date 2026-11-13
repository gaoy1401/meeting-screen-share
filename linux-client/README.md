# Meeting Linux Client

Ubuntu 24.04 X11 / GTK4 客户端默认使用 LiveKit WebRTC：

- `app.py`：GTK UI 与传输适配选择；
- `signaling.py`：TCP 可靠入会和短期 JWT；
- `livekit_transport.py`：ICE/DTLS/SRTP、Opus 音频和视频轨；
- `raw_screen.py`：GStreamer 采集 1920×1080、30 FPS I420 屏幕帧；
- `hardware_screen.py`：PXG 专用的 GStreamer NVENC H.264 发布器；
- `transport.py`、`audio.py`、`screen.py`：旧 UDP 回退模块。

## 依赖

从项目根目录进入 `linux-client`，安装系统包：

```bash
sudo apt-get update
sudo apt-get install -y \
  python3 python3-venv python3-gi gir1.2-gtk-4.0 gir1.2-gstreamer-1.0 \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-tools gstreamer1.0-x
cd linux-client
```

依赖包括：

```text
python3
python3-venv
python3-gi
gir1.2-gtk-4.0
gir1.2-gstreamer-1.0
gstreamer1.0-plugins-base
gstreamer1.0-plugins-good
gstreamer1.0-plugins-bad
```

项目虚拟环境：

```bash
python3 -m venv --system-site-packages ../.venv
../.venv/bin/pip install -r requirements-webrtc.txt
```

运行：

```bash
./run-client.sh
```

默认 `MEETING_MEDIA_TRANSPORT=webrtc`。旧链路回归时使用：

```bash
MEETING_MEDIA_TRANSPORT=udp ./run-client.sh
```

默认屏幕编码为 H.264。PXG 单独与支持 HEVC 的终端测试时使用：

```bash
MEETING_VIDEO_CODEC=hevc ./run-client.sh
```

如果 HEVC 发布失败，客户端会自动重新用 H.264 发布并在状态栏说明。需要与
Windows 客户端互通的会议应保持 H.264，因为 SFU 不负责转码。

可选的 NVIDIA 部署可使用独立的
`meeting-hardware-screen.service` 使用 `nvh264enc` 生成 1920×1080、30 FPS、
6 Mbps 的 Annex-B H.264，再由 LiveKit CLI 发布。GTK 客户端仍负责音频、
远端画面和会议控制，两个模块可以独立重启。

PXG 没有物理音频端点时，UI 仍可能显示音轨已发布；这只能证明 WebRTC 音轨
建立，不能证明真实麦克风采音或扬声器出声。

屏幕采集使用 `ximagesrc`，需要 X11 会话；Wayland 原生采集尚未实现。
硬件发布器是可选项，需要 NVIDIA 驱动、`nvh264enc` 和 LiveKit CLI，普通客户端不需要。
