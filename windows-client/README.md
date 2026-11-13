# Windows 原生客户端

这是独立的 Windows x64 客户端，不依赖浏览器。各模块边界如下：

```text
meeting_window       Win32 UI 与远端 BGRA 画面渲染
control_protocol     JSON 行协议的编码/解析
signaling_client     TCP 9000 获取短期 LiveKit 凭证
meeting_client       房间、音轨、屏幕轨和状态编排
screen_capturer      GDI 桌面采集，输出 1920x1080、30 FPS BGRA
serial_executor      串行执行连接和媒体状态变化
codec_policy         集中隔离 SDK 的编码枚举映射
```

## 构建环境

- Windows 10/11 x64
- Visual Studio 2022，安装“使用 C++ 的桌面开发”
- CMake 3.20 或更高版本
- 首次配置时可以访问 GitHub

在 PowerShell 中运行：

```powershell
cd windows-client
.\scripts\build.ps1
```

脚本固定下载 LiveKit C++ SDK 1.4.0，并校验 SHA-256。成功后启动：

```powershell
.\build\Release\MeetingClient.exe
```

可直接复制到其他 Windows x64 机器的包会生成在：

```text
dist\MeetingClient-Windows-x64.zip
```

要生成适合直接发给其他人的免安装 ZIP、带卸载入口的安装包和 SHA-256
校验文件，运行：

```powershell
.\scripts\build-release.ps1 -InstallInnoSetup
```

完整交付步骤、代码签名和接收方操作见
[`DISTRIBUTION.md`](DISTRIBUTION.md)。

默认服务器为 `127.0.0.1:9000`。连接其他电脑上的服务端时，改为你自己的
服务端地址。所有参与者填写同一房间号（例如 `demo`）。本项目不提供公共默认服务器。

## 当前编码边界

- Windows 发布和接收 H.264，音频为 Opus；
- 屏幕共享目标为 1920×1080、30 FPS、最高 6 Mbps；
- 接收画面使用持久双缓冲一次性呈现，不再逐帧先清黑屏再绘制；
- WebRTC 媒体优先通过 UDP 7882，受阻时由 ICE 回落 TCP 7881；
- LiveKit C++ SDK 1.4.0 的 Windows 预编译包没有 H.265 编解码后端，因此
  Windows 端不能宣称已经支持 HEVC；
- Mac/PXG 可通过 `MEETING_VIDEO_CODEC=hevc` 请求 HEVC，但需要和
  Windows 互通的会议应保持 H.264，或让发布端同时提供 H.264 备份编码。

## Windows 验收

1. PXG 上三个服务均为 `active`；
2. Windows 加入 `demo` 后显示 `2 人在线` 或更多；
3. 开启麦克风后，另一台有扬声器的设备能听到声音；
4. 开启共享屏幕后，Mac/PXG 能持续看到 Windows 桌面；
5. Windows 能显示 PXG/Mac 的 H.264 屏幕轨；
6. LiveKit 日志中的 Windows participant 使用 UDP candidate pair，视频 MIME
   为 `video/H264`。
