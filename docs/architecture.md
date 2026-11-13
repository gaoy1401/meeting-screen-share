# 模块化架构

## 默认 WebRTC 数据路径

```text
Mac / Linux / Windows 客户端
  │
  ├─ TCP 9000 ─> SignalingServer ─> 短期房间 JWT
  │
  └─ WebRTC ───> LiveKit SFU
                  ├─ 7880/TCP: WebSocket 信令
                  ├─ 7881/TCP: ICE/TCP 回退
                  └─ 7882/UDP: ICE/DTLS/SRTP 媒体
```

音频和屏幕的具体路径：

```text
麦克风 ─> LiveKit SDK ─> Opus/RED ─> SRTP ─> SFU ─> 远端自动播放
屏幕帧 ─> LiveKit SDK ─> 协商视频编码 ─> SRTP ─> SFU ─> 远端 VideoTrack
```

客户端不再自己决定重传关键帧或盲目重复 UDP 包。WebRTC 层统一负责：

- ICE 候选选择与 UDP/TCP 回退；
- DTLS 密钥协商和 SRTP 加密；
- RTCP 接收报告、NACK、PLI；
- 抖动处理、带宽估计和拥塞控制；
- 编码能力协商。

## 模块边界

### 服务端

- `livekit-token.js`：只签发房间级短期 JWT，不接触媒体。
- `signaling-server.js`：可靠加入/离开、WebRTC 或 UDP 路由选择。
- `config.js`：集中处理端口、LiveKit 地址和令牌有效期。
- `meeting-server.js`：旧 UDP 回退服务的网络编排。
- LiveKit 进程：正式的 WebRTC SFU 媒体层。

### macOS

- `MeetingWebRTC`：封装 LiveKit Room、麦克风、屏幕和远端视频轨。
- `MeetingTransport`：TCP 信令与旧 UDP 实现。
- `MeetingMedia`：旧 UDP 所需的 Opus/H.264 编解码与缓冲。
- `MeetingClient`：只做 UI 和状态编排，根据环境选择适配层。

### Linux

- `livekit_transport.py`：异步 Room、音轨、屏幕轨和远端视频流。
- `raw_screen.py`：GStreamer 采集 I420 原始帧，编码交给 WebRTC。
- `signaling.py`：TCP 加入与令牌响应。
- `transport.py`、`audio.py`、`screen.py`：旧 UDP 回退模块。
- `app.py`：GTK UI 和两种适配层的选择。

### Windows

- `meeting_window`：Win32 UI 和 BGRA 画面渲染。
- `control_protocol`、`signaling_client`：JSON 行协议与 TCP 入会。
- `meeting_client`：LiveKit Room、系统音频、屏幕轨和远端轨编排。
- `screen_capturer`：GDI 桌面采集，只生产原始帧。

可选的 NVIDIA Linux 屏幕发布拆成独立硬件链路：

```text
ximagesrc -> BGRA -> nvh264enc -> Annex-B H264 -> LiveKit CLI -> SFU
```

`meeting-linux-webrtc.service` 保留 GTK、音频、订阅和控制；
`meeting-hardware-screen.service` 只负责 NVIDIA H.264 屏幕轨。辅助发布者
使用固定 identity `pxg-screen`，各客户端把它合并进 PXG 的人数显示。
- `serial_executor`：把连接、发布和停止操作串行化。
- `codec_policy`：集中隔离 SDK 编码枚举，不让协议值散落在 UI。

## 编码策略

默认优先三端稳定兼容：

- 音频：Opus，服务端观测到 RED 冗余封装；
- 屏幕：1920×1080、30 FPS、上限约 6 Mbps；
- 默认屏幕编码：H.264；
- Mac/PXG 设置 `MEETING_VIDEO_CODEC=hevc` 后请求 H.265，发布失败时回落 H.264；
- Mac 的 HEVC 发布同时声明 H.264 备份编码。

H.265/HEVC 是编码层增强，不会替换 ICE/DTLS/SRTP、NACK、PLI 和拥塞控制。
当前 LiveKit C++ SDK 1.4.0 的 Windows 预编译包没有 H.265 编解码后端，
因此包含 Windows 的会议必须有 H.264 轨可用。SFU 只转发、不转码，不能把
PXG 的单一 HEVC 轨临时变成 H.264。

## 生产边界

当前配置适合可信 LAN。公网版本仍需：

- HTTPS/WSS 反向代理和可信证书；
- TURN/TLS 443 回退；
- 用户登录、会议权限与服务端鉴权；
- 随机密钥和安全密钥存储；
- 指标、日志脱敏、配额、录制权限与多实例路由。
