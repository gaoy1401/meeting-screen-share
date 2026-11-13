# Meeting Screen Share

[![CI](https://github.com/gaoy1401/meeting-screen-share/actions/workflows/ci.yml/badge.svg)](https://github.com/gaoy1401/meeting-screen-share/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gaoy1401/meeting-screen-share?include_prereleases&label=preview)](https://github.com/gaoy1401/meeting-screen-share/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

基于 WebRTC + LiveKit 的原生屏幕共享和语音会议软件，包含 macOS、Windows、
Linux 客户端及自部署服务端。当前是 **0.1.0 开发预览版**。

## 下载安装包（v0.1.0 预览版）

**[打开全部安装包和 SHA-256 校验文件](https://github.com/gaoy1401/meeting-screen-share/releases/tag/v0.1.0)**

| 系统 | 直接下载 | 安装方法 |
| --- | --- | --- |
| macOS 13+，Apple Silicon（M 系列） | [下载 Mac 应用 ZIP](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-0.1.0-macos-arm64.zip) | 解压，把 `MeetingClient.app` 拖入“应用程序”。[Mac 安装说明](docs/INSTALL_MAC.md) |
| Windows 10/11 x64 | [下载 Windows 安装程序（.exe）](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-Setup-0.1.0-x64.exe) · [免安装 ZIP](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-Windows-x64.zip) | 双击安装程序，或按[免安装说明](windows-client/DISTRIBUTION.md)运行。 |
| Linux（X11） | [Linux 部署说明](linux-client/README.md) | 从源码运行；本版本未提供 Linux 安装包。 |

Mac 和 Windows 用户下载上面的客户端即可，无需自己编译。
已有服务端时，安装后填写服务端地址和房间号；首次部署可参考
[Mac 服务端启动教程](mac-server/README.md)或下方的手动部署说明。
当前仍为预览版：Mac 未做 Apple 公证，Windows 安装程序未配置发行者签名。

## 使用前先了解

- 没有公共默认服务器，需要自己启动服务端。
- 客户端默认 `127.0.0.1:9000`；连接其他电脑时改为服务端实际地址。
- 控制连接仍是明文 TCP，没有登录和房间权限校验，只适合可信局域网或 VPN。
- 默认 H.264 + Opus；Linux 采集需要 X11，Windows 当前不支持 HEVC。
- 入会成功不等于音视频验收，需要两台设备实际互看画面、互听声音。

## 最快开始：在 Mac 上启动服务端

安装 Homebrew 后，在项目根目录执行：

```sh
./mac-server/bin/install.sh
./mac-server/bin/start.sh
./scripts/build-client.sh
open dist/mac/MeetingClient.app
```

启动脚本会生成随机密钥并打印局域网地址。两台设备填写相同服务器地址和
房间号，手动开启麦克风或选择共享内容。首次使用需授予麦克风和录屏权限。

```sh
./mac-server/bin/check.sh
./mac-server/bin/stop.sh
```

## 各平台安装

| 平台 | 要求 | 安装 / 构建 |
| --- | --- | --- |
| macOS | macOS 13+；构建需要 Swift 6 / Xcode 16+ | `./scripts/package-mac.sh`；解压 ZIP，把 app 拖入应用程序 |
| Windows | Windows 10/11 x64；构建需要 VS 2022 C++、CMake | Windows 上运行 `windows-client/scripts/build-release.ps1` |
| Linux | Ubuntu 24.04、X11、Python 3.10+、GTK4/GStreamer | 按 Linux README 从源码启动 |

Mac 预览包是 ad-hoc 签名，未做 Apple 公证；Windows 默认未配置发行者签名。
系统可能提示未知发布者。请按 CPU 架构下载；Mac 协议检查不能代替 Windows 安装验收。

[Mac 安装](docs/INSTALL_MAC.md) · [Windows](windows-client/README.md) 
[Linux](linux-client/README.md) · [发布步骤](docs/RELEASING.md)

## 手动搭建 Linux / Mac 服务端

准备 Node.js 22+ 和 LiveKit Server；把示例 IP 换成自己的服务器 IP：

```sh
npm ci --prefix server
python3 scripts/configure-server.py --ip 192.168.1.10
livekit-server --config .runtime/server/livekit.yaml
```

另开终端，在项目根目录执行：

```sh
set -a
. .runtime/server/control.env
set +a
node server/src/index.js
```

TCP 9000 为控制连接，TCP 7880 为 LiveKit 信令，UDP 7882 / TCP 7881 为媒体。
生成的配置在 `.runtime/` 中，不纳入源码或 Git。更换网络后同时修改服务端公告
地址和客户端填写的地址。

## 验证与贡献

```sh
npm test --prefix server
PYTHONPATH=linux-client python3 linux-client/check-client.py
PYTHONPATH=linux-client python3 linux-client/check-hardware-screen.py
```

完整验收见 [测试计划](docs/test-plan.md)。GitHub Actions 提供跨平台 CI 和安装包构建；每个版本首次通过主分支 CI 后，
自动发布预览版到 [Releases](https://github.com/gaoy1401/meeting-screen-share/releases)。
已有版本的安装包不会被自动覆盖。项目采用 [MIT](LICENSE)，依赖保留各自的[许可证](THIRD_PARTY_NOTICES.md)。
