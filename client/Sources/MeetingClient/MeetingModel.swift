import AppKit
import AVFoundation
import Foundation
import MeetingCore
import MeetingMedia
import MeetingTransport
import MeetingWebRTC

@MainActor
final class MeetingModel: ObservableObject {
    private enum MediaTransportMode {
        case webRTC
        case udp
    }

    @Published var serverAddress: String
    @Published var roomID: String
    @Published var displayName: String
    @Published private(set) var status = "尚未连接"
    @Published private(set) var isConnected = false
    @Published private(set) var participantCount = 0
    @Published private(set) var receivedScreen: NSImage?
    @Published private(set) var remoteWebRTCVideo: WebRTCVideoTrackHandle?
    @Published var microphoneEnabled = false
    @Published var screenShareEnabled = false
    @Published var shareSystemAudioEnabled = true
    @Published var selectedScreenShareSourceID: String?
    @Published private(set) var screenShareSources: [WebRTCScreenShareSource] = []
    @Published private(set) var isLoadingScreenShareSources = false

    private let sessionID = UInt32.random(in: 1...UInt32.max)
    private let transport = UDPTransport()
    private let signaling = SignalingTransport()
    private let webRTC = WebRTCMeetingClient()
    private let mediaTransportMode: MediaTransportMode
    private let audio: AudioController
    private let mediaReceiver: RTPMediaReceiver
    private let screenShare = ScreenShareController()
    private let h264Encoder = H264Encoder()
    private let h264Packetizer = H264RTPPacketizer()
    private var controlSequence: UInt32 = 0
    private var audioSequence = UInt16.random(in: 0...UInt16.max)
    private var videoSequence = UInt16.random(in: 0...UInt16.max)
    private var udpBindRetry: Timer?
    private let autoJoinRequested: Bool
    private var attemptedAutoJoin = false
    private var pendingEndpoint: (host: String, port: UInt16)?
    private var udpBindToken: String?
    private var hasReceivedH264 = false
    private var hasDecodedOpus = false
    private var processActivity: NSObjectProtocol?

    init() {
        let audio = AudioController()
        self.audio = audio
        self.mediaReceiver = RTPMediaReceiver(audio: audio)

        let environment = ProcessInfo.processInfo.environment
        serverAddress = environment["MEETING_SERVER"] ?? "127.0.0.1:9000"
        roomID = environment["MEETING_ROOM"] ?? "demo"
        displayName = environment["MEETING_NAME"] ??
            Host.current().localizedName ?? "Mac"
        autoJoinRequested = environment["MEETING_AUTO_JOIN"] == "1"
        mediaTransportMode =
            environment["MEETING_MEDIA_TRANSPORT"]?.lowercased() == "udp"
            ? .udp
            : .webRTC

        transport.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleUDPState(state) }
        }
        transport.onPacket = { [weak self] packet in
            Task { @MainActor in self?.handle(packet) }
        }
        transport.onRTPPacket = { [weak self] packet in
            self?.mediaReceiver.ingest(packet)
        }
        signaling.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleSignalingState(state) }
        }
        signaling.onMessage = { [weak self] body in
            Task { @MainActor in self?.handleSignaling(body) }
        }
        webRTC.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleWebRTCState(state) }
        }
        webRTC.onParticipantCount = { [weak self] count in
            Task { @MainActor in self?.participantCount = count }
        }
        webRTC.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in self?.remoteWebRTCVideo = track }
        }
        audio.onCapturedOpus = { [weak self] data, timestamp in
            Task { @MainActor in self?.sendAudio(data, timestamp: timestamp) }
        }
        mediaReceiver.onDecodedOpus = { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasDecodedOpus else { return }
                self.hasDecodedOpus = true
                self.updateReceivedMediaStatus()
            }
        }
        screenShare.onCapturedFrame = { [weak self] pixelBuffer, presentationTime in
            self?.h264Encoder.encode(pixelBuffer, presentationTime: presentationTime)
        }
        h264Encoder.onAccessUnit = { [weak self] data, timestamp, isKeyFrame in
            Task { @MainActor in
                self?.sendScreen(
                    data,
                    timestamp: timestamp,
                    duplicateForRecovery: isKeyFrame
                )
            }
        }
        mediaReceiver.onImage = { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                self.receivedScreen = image
                if !self.hasReceivedH264 {
                    self.hasReceivedH264 = true
                    self.updateReceivedMediaStatus()
                }
            }
        }
    }

    func startIfRequested() {
        guard autoJoinRequested, !attemptedAutoJoin else { return }
        attemptedAutoJoin = true
        connect()
    }

    func connect() {
        guard !isConnected else {
            disconnect()
            return
        }
        guard let endpoint = parseEndpoint(serverAddress) else {
            status = "服务器地址格式应为 主机:端口"
            return
        }
        guard roomID.range(
            of: #"^[A-Za-z0-9_-]{2,64}$"#,
            options: .regularExpression
        ) != nil else {
            status = "房间号只能包含字母、数字、下划线或连字符"
            return
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "请输入昵称"
            return
        }

        pendingEndpoint = endpoint
        status = "正在连接可靠信令…"
        signaling.connect(host: endpoint.host, port: endpoint.port)
    }

    func disconnect() {
        signaling.send(["action": "leave"])
        if mediaTransportMode == .udp {
            sendUDPControl(["action": "leave"])
        } else {
            Task { await webRTC.disconnect() }
        }
        udpBindRetry?.invalidate()
        udpBindRetry = nil
        transport.stopHeartbeat()
        microphoneEnabled = false
        screenShareEnabled = false
        screenShareSources = []
        selectedScreenShareSourceID = nil
        isLoadingScreenShareSources = false
        audio.stop()
        Task { await screenShare.stop() }
        h264Encoder.stop()
        mediaReceiver.reset()
        receivedScreen = nil
        remoteWebRTCVideo = nil
        hasReceivedH264 = false
        hasDecodedOpus = false
        participantCount = 0
        isConnected = false
        transport.disconnect()
        signaling.disconnect()
        endMeetingActivity()
        pendingEndpoint = nil
        udpBindToken = nil
        status = "已断开"
    }

    func setMicrophone(_ enabled: Bool) {
        guard isConnected else {
            microphoneEnabled = false
            return
        }
        if enabled {
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    await MainActor.run {
                        self.microphoneEnabled = false
                        self.status = "没有麦克风权限，请在系统设置中允许"
                    }
                    return
                }
                if self.mediaTransportMode == .webRTC {
                    do {
                        try await self.webRTC.setMicrophone(enabled: true)
                        await MainActor.run {
                            self.microphoneEnabled = true
                            self.status = "麦克风已开启，音频使用 WebRTC/Opus"
                        }
                    } catch {
                        await MainActor.run {
                            self.microphoneEnabled = false
                            self.status = "麦克风启动失败：\(error.localizedDescription)"
                        }
                    }
                    return
                }
                await MainActor.run {
                    do {
                        try self.audio.startMicrophone()
                        self.microphoneEnabled = true
                        self.status = "麦克风已开启"
                    } catch {
                        self.microphoneEnabled = false
                        self.status = "麦克风启动失败：\(error.localizedDescription)"
                    }
                }
            }
        } else {
            microphoneEnabled = false
            if mediaTransportMode == .webRTC {
                Task {
                    do {
                        try await webRTC.setMicrophone(enabled: false)
                        await MainActor.run {
                            self.status = self.screenShareEnabled
                                ? (self.shareSystemAudioEnabled
                                    ? "正在共享画面和系统声音，麦克风已关闭"
                                    : "正在共享画面，麦克风已关闭")
                                : "麦克风已关闭"
                        }
                    } catch {
                        await MainActor.run {
                            self.status = "关闭麦克风失败：\(error.localizedDescription)"
                        }
                    }
                }
            } else {
                audio.stopMicrophone()
            }
        }
    }

    func setScreenShare(_ enabled: Bool) {
        guard isConnected else {
            screenShareEnabled = false
            return
        }
        if enabled {
            if mediaTransportMode == .webRTC {
                Task {
                    if shareSystemAudioEnabled {
                        let granted = await AVCaptureDevice.requestAccess(for: .audio)
                        guard granted else {
                            await MainActor.run {
                                self.screenShareEnabled = false
                                self.status =
                                    "共享系统声音需要音频权限，请在系统设置中允许"
                            }
                            return
                        }
                    }
                    do {
                        try await webRTC.setScreenShare(
                            enabled: true,
                            sourceID: selectedScreenShareSourceID,
                            includeSystemAudio: shareSystemAudioEnabled
                        )
                        await MainActor.run {
                            self.screenShareEnabled = true
                            self.status = self.shareSystemAudioEnabled
                                ? "正在共享画面和系统声音"
                                : "正在共享画面"
                        }
                    } catch {
                        await MainActor.run {
                            self.screenShareEnabled = false
                            self.status = "屏幕共享失败：\(error.localizedDescription)"
                        }
                    }
                }
                return
            }
            Task {
                do {
                    try await screenShare.start()
                    await MainActor.run {
                        self.screenShareEnabled = true
                        self.status = "正在共享屏幕"
                    }
                } catch {
                    await MainActor.run {
                        self.screenShareEnabled = false
                        self.status = "屏幕共享失败：\(error.localizedDescription)"
                    }
                }
            }
        } else {
            screenShareEnabled = false
            if mediaTransportMode == .webRTC {
                Task {
                    do {
                        try await webRTC.setScreenShare(enabled: false)
                        await MainActor.run {
                            self.status = "屏幕共享和系统声音已停止"
                        }
                    } catch {
                        await MainActor.run {
                            self.status = "停止屏幕共享失败：\(error.localizedDescription)"
                        }
                    }
                }
            } else {
                Task { await screenShare.stop() }
                h264Encoder.stop()
            }
        }
    }

    func refreshScreenShareSources() {
        guard isConnected, mediaTransportMode == .webRTC,
              !isLoadingScreenShareSources else { return }
        isLoadingScreenShareSources = true
        status = "正在读取可共享的显示器和窗口…"
        Task {
            do {
                let sources = try await webRTC.availableScreenShareSources()
                await MainActor.run {
                    self.screenShareSources = sources
                    if self.selectedScreenShareSourceID == nil ||
                        !sources.contains(where: {
                            $0.id == self.selectedScreenShareSourceID
                        }) {
                        self.selectedScreenShareSourceID = sources.first?.id
                    }
                    self.isLoadingScreenShareSources = false
                    self.status = sources.isEmpty
                        ? "没有找到可共享的显示器或窗口"
                        : "请选择要共享的显示器或窗口"
                }
            } catch {
                await MainActor.run {
                    self.isLoadingScreenShareSources = false
                    self.status =
                        "读取共享内容失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func handleUDPState(_ state: TransportState) {
        switch state {
        case .idle:
            break
        case .connecting:
            status = "正在建立 UDP 媒体通道…"
        case .ready:
            beginUDPBindRetries()
            status = "正在绑定 UDP 媒体通道…"
        case .failed(let message):
            udpBindRetry?.invalidate()
            udpBindRetry = nil
            status = "UDP 媒体错误：\(message)"
            isConnected = false
            endMeetingActivity()
        }
    }

    private func handleSignalingState(_ state: SignalingState) {
        switch state {
        case .idle:
            break
        case .connecting:
            status = "正在连接可靠信令…"
        case .ready:
            signaling.send([
                "action": "join",
                "room": roomID,
                "name": String(displayName.prefix(32)),
                "sessionId": sessionID,
                "transport": mediaTransportMode == .webRTC ? "webrtc" : "udp"
            ])
            status = "正在可靠加入房间…"
        case .failed(let message):
            status = "信令连接错误：\(message)"
            isConnected = false
            endMeetingActivity()
        }
    }

    private func handle(_ packet: MediaPacket) {
        guard packet.sessionID != sessionID || packet.type == .control else { return }
        switch packet.type {
        case .control:
            handleUDPControl(packet.payload)
        case .audio:
            break
        case .screen:
            break
        }
    }

    private func handleUDPControl(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return }
        if action == "error" {
            let message = (object["message"] as? String) ?? "未知错误"
            if isConnected, message == "not joined" {
                recoverUDPBinding()
            } else {
                status = "服务器拒绝 UDP 绑定：\(message)"
            }
        }
    }

    private func recoverUDPBinding() {
        isConnected = false
        transport.stopHeartbeat()
        udpBindRetry?.invalidate()
        udpBindRetry = nil
        udpBindToken = nil
        status = "UDP 会话已失效，正在重新加入房间…"
        signaling.send([
            "action": "join",
            "room": roomID,
            "name": String(displayName.prefix(32)),
            "sessionId": sessionID
        ])
    }

    private func handleSignaling(_ object: [String: Any]) {
        guard let action = object["action"] as? String else { return }
        switch action {
        case "webrtc_connect":
            guard mediaTransportMode == .webRTC,
                  let url = object["url"] as? String,
                  let token = object["token"] as? String else { return }
            status = "正在连接 WebRTC SFU…"
            Task {
                do {
                    try await webRTC.connect(url: url, token: token)
                } catch {
                    await MainActor.run {
                        self.status = "WebRTC 入会失败：\(error.localizedDescription)"
                        self.isConnected = false
                        self.endMeetingActivity()
                    }
                }
            }
        case "udp_bind":
            guard mediaTransportMode == .udp else { return }
            guard let token = object["token"] as? String,
                  let endpoint = pendingEndpoint else { return }
            udpBindToken = token
            transport.connect(host: endpoint.host, port: endpoint.port)
            status = "正在建立 UDP 媒体通道…"
        case "joined":
            udpBindRetry?.invalidate()
            udpBindRetry = nil
            isConnected = true
            beginMeetingActivity()
            status = "已加入房间 \(roomID)，媒体使用 UDP"
            do {
                try audio.startPlayback()
            } catch {
                status = "已加入，但扬声器启动失败：\(error.localizedDescription)"
            }
            signaling.send(["action": "heartbeat"])
            transport.startHeartbeat(sessionID: sessionID)
        case "snapshot":
            participantCount = (object["participants"] as? [[String: Any]])?.count ?? 0
        case "error":
            status = "服务器拒绝：\((object["message"] as? String) ?? "未知错误")"
            isConnected = false
        default:
            break
        }
    }

    private func handleWebRTCState(_ state: WebRTCMeetingState) {
        switch state {
        case .idle:
            break
        case .connecting:
            status = "正在连接 WebRTC SFU…"
        case .connected:
            isConnected = true
            beginMeetingActivity()
            status = "已加入房间 \(roomID)，媒体使用 WebRTC/SRTP"
        case .reconnecting:
            status = "网络波动，WebRTC 正在自动重连…"
        case .disconnected:
            if isConnected {
                status = "WebRTC 已断开"
            }
            isConnected = false
            endMeetingActivity()
        case .failed(let message):
            status = "WebRTC 媒体错误：\(message)"
            isConnected = false
            endMeetingActivity()
        }
    }

    private func sendUDPControl(_ body: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        send(type: .control, payload: data)
    }

    private func beginUDPBindRetries() {
        udpBindRetry?.invalidate()
        sendUDPBindOnce()
        udpBindRetry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] timer in
            Task { @MainActor in
                guard let self, !self.isConnected else {
                    timer.invalidate()
                    return
                }
                self.sendUDPBindOnce()
            }
        }
    }

    private func sendUDPBindOnce() {
        guard !isConnected, let udpBindToken else { return }
        sendUDPControl([
            "action": "join",
            "room": roomID,
            "name": String(displayName.prefix(32)),
            "token": udpBindToken
        ])
    }

    private func sendAudio(_ data: Data, timestamp: UInt32) {
        guard isConnected, microphoneEnabled else { return }
        audioSequence &+= 1
        transport.send(
            RTPPacket(
                marker: true,
                payloadType: .opus,
                sequence: audioSequence,
                timestamp: timestamp,
                ssrc: sessionID,
                payload: data
            )
        )
    }

    private func sendScreen(
        _ data: Data,
        timestamp: UInt32,
        duplicateForRecovery: Bool
    ) {
        guard isConnected, screenShareEnabled, !data.isEmpty else { return }
        let packets = h264Packetizer.packetize(
            accessUnit: data,
            timestamp: timestamp,
            ssrc: sessionID
        ) {
            self.videoSequence &+= 1
            return self.videoSequence
        }
        for packet in packets {
            transport.send(packet)
            if duplicateForRecovery {
                transport.send(packet)
            }
        }
    }

    private func send(
        type: MediaPacketType,
        payload: Data,
        frameID: UInt32 = 0,
        chunkIndex: UInt16 = 0,
        chunkCount: UInt16 = 0
    ) {
        controlSequence &+= 1
        transport.send(
            MediaPacket(
                type: type,
                sessionID: sessionID,
                sequence: controlSequence,
                frameID: frameID,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                payload: payload
            )
        )
    }

    private func updateReceivedMediaStatus() {
        guard isConnected else { return }
        if hasReceivedH264, hasDecodedOpus {
            status = "已加入房间 \(roomID)，已接收 H.264 画面与 Opus 音频"
        } else if hasReceivedH264 {
            status = "已加入房间 \(roomID)，已接收 H.264 画面"
        } else if hasDecodedOpus {
            status = "已加入房间 \(roomID)，已解码 Opus 音频"
        }
    }

    private func beginMeetingActivity() {
        guard processActivity == nil else { return }
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "保持会议信令和实时媒体处理"
        )
    }

    private func endMeetingActivity() {
        guard let processActivity else { return }
        ProcessInfo.processInfo.endActivity(processActivity)
        self.processActivity = nil
    }

    private func parseEndpoint(_ value: String) -> (host: String, port: UInt16)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":"),
              separator != trimmed.startIndex,
              let port = UInt16(trimmed[trimmed.index(after: separator)...]) else {
            return nil
        }
        var host = String(trimmed[..<separator])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return host.isEmpty ? nil : (host, port)
    }
}
