# 会议信令与媒体协议 v3

## WebRTC 默认路径

客户端先连接 `9000/TCP`，每行发送一个 UTF-8 JSON 对象：

```json
{"action":"join","room":"demo","name":"Alice","sessionId":123,"transport":"webrtc"}
```

服务端签发仅允许加入指定房间、发布和订阅媒体的短期 JWT：

```json
{"action":"webrtc_connect","room":"demo","url":"ws://192.168.1.10:7880","token":"..."}
```

JWT 不写入日志、不通过 UDP 发送。客户端随后直接连接 LiveKit：

1. `7880/TCP` 完成 WebSocket 信令；
2. ICE 优先选择 `7882/UDP`；
3. UDP 不可用时尝试 `7881/TCP`；
4. DTLS 派生会话密钥，音视频使用 SRTP；
5. SFU 只转发已发布的轨道，不解码业务内容。

媒体包格式、序号、RTCP、NACK/PLI 和重传均由 WebRTC SDK 管理，不再属于
本项目的自定义应用层协议。

## 旧 UDP 回退路径

客户端设置 `MEETING_MEDIA_TRANSPORT=udp` 后仍可发送：

```json
{"action":"join","room":"demo","name":"Alice","sessionId":123,"transport":"udp"}
```

服务端返回一次性 `udp_bind` 令牌，之后使用原有：

- `9000/UDP`；
- H.264 RTP，Payload Type 96，90 kHz；
- Opus RTP，Payload Type 111，48 kHz；
- `MSH1` 控制包；
- RTP SSRC 等于 `sessionId`。

这个分支只用于回归和故障隔离，不具备 SRTP、完整 RTCP、NAT 穿透与成熟拥塞
控制，不能作为公网默认媒体链路。
