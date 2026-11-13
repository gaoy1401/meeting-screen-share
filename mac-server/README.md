# macOS 会议服务器

Mac 服务器复用项目现有协议，由两个独立进程组成：

- LiveKit SFU：WebRTC 信令、ICE、DTLS/SRTP、音视频转发；
- Node 控制服务：`9000/TCP` 入会、短期 JWT，以及旧 `9000/UDP` 回退。

## 安装与启动

```bash
./mac-server/bin/install.sh
./mac-server/bin/start.sh
```

启动脚本会自动识别当前局域网 IPv4，首次生成仅保存在本机的 API 密钥，并打印
客户端应该填写的服务器地址。

同一台 Mac 上的客户端填写：

```text
127.0.0.1:9000
```

局域网其他客户端填写启动结果中的地址，例如：

```text
192.168.3.42:9000
```

房间号仍为 `demo`。首次启动时，如果 macOS 防火墙询问是否允许网络访问，应
允许 `node` 和 `livekit-server` 接收入站连接。

## 独立管理命令

```bash
./mac-server/bin/status.sh
./mac-server/bin/check.sh
./mac-server/bin/stop.sh
```

运行时配置和日志位于：

```text
.runtime/mac-server/
```

两个进程由当前用户的 macOS `launchd` 域管理，关闭终端后仍会运行；服务异常
退出时 `launchd` 会自动重新启动。`stop.sh` 会明确卸载两个服务。

需要指定另一块网卡的地址时：

```bash
MEETING_MAC_SERVER_IP=192.168.3.42 ./mac-server/bin/start.sh
```

## 端口

| 端口 | 协议 | 用途 |
|---|---|---|
| 9000 | TCP | 入会控制和短期 JWT |
| 7880 | TCP | LiveKit WebSocket/API |
| 7881 | TCP | WebRTC ICE/TCP 回退 |
| 7882 | UDP | WebRTC ICE/UDP 媒体 |
| 9000 | UDP | 旧媒体回退 |

这套配置用于可信局域网测试。公网部署还需要 TLS/WSS、TURN、真实身份认证、
防火墙策略和安全的密钥管理。
