import CoreGraphics
import Foundation
import LiveKit
import SwiftUI

public enum WebRTCMeetingState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed(String)
}

public final class WebRTCVideoTrackHandle: @unchecked Sendable {
    fileprivate let track: VideoTrack

    fileprivate init(track: VideoTrack) {
        self.track = track
    }
}

public struct WebRTCScreenShareSource: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case display
        case window
    }

    public let id: String
    public let name: String
    public let kind: Kind

    fileprivate init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct WebRTCVideoSurface: View {
    private let handle: WebRTCVideoTrackHandle

    public init(_ handle: WebRTCVideoTrackHandle) {
        self.handle = handle
    }

    public var body: some View {
        SwiftUIVideoView(
            handle.track,
            layoutMode: .fit,
            mirrorMode: .off
        )
    }
}

public final class WebRTCMeetingClient: NSObject, RoomDelegate, @unchecked Sendable {
    public var onStateChange: ((WebRTCMeetingState) -> Void)?
    public var onParticipantCount: ((Int) -> Void)?
    public var onRemoteVideoTrack: ((WebRTCVideoTrackHandle?) -> Void)?

    private lazy var room = Room(delegate: self)
    private let preferredVideoCodec: VideoCodec
    private let auxiliaryScreenIdentity = "pxg-screen"
    private var screenSources: [String: MacOSScreenCaptureSource] = [:]
    private var screenPublication: LocalTrackPublication?
    private var microphoneRequested = false
    private var systemAudioRequested = false

    public override init() {
        let requestedCodec = ProcessInfo.processInfo.environment["MEETING_VIDEO_CODEC"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        preferredVideoCodec = requestedCodec == "hevc" || requestedCodec == "h265"
            ? .h265
            : .h264
        super.init()
        // This Mac produced repeated Voice-Processing I/O aggregate-device
        // failures. Disable that device path before the peer connection is
        // created; the microphone track explicitly enables WebRTC software
        // AEC/AGC/noise suppression below.
        try? AudioManager.shared.setVoiceProcessingEnabled(false)
    }

    public func connect(url: String, token: String) async throws {
        onStateChange?(.connecting)
        do {
            try await room.connect(url: url, token: token)
            emitConnectedState()
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            throw error
        }
    }

    public func disconnect() async {
        await room.disconnect()
        screenPublication = nil
        screenSources.removeAll()
        microphoneRequested = false
        systemAudioRequested = false
        AudioManager.shared.mixer.micVolume = 1
        AudioManager.shared.mixer.appVolume = 1
        onRemoteVideoTrack?(nil)
        onParticipantCount?(0)
        onStateChange?(.disconnected)
    }

    public func setMicrophone(enabled: Bool) async throws {
        microphoneRequested = enabled
        try await synchronizeOutgoingAudio()
    }

    public func availableScreenShareSources() async throws -> [WebRTCScreenShareSource] {
        guard #available(macOS 12.3, *) else { return [] }

        let nativeSources = try await MacOSScreenCapturer.sources(
            for: .any,
            includeCurrentApplication: true
        )
        var mappedSources: [String: MacOSScreenCaptureSource] = [:]
        let sources = nativeSources.compactMap {
            nativeSource -> WebRTCScreenShareSource? in
            if let display = nativeSource as? MacOSDisplay {
                let id = "display:\(display.displayID)"
                mappedSources[id] = display
                let prefix = display.displayID == CGMainDisplayID()
                    ? "主显示器"
                    : "显示器"
                return WebRTCScreenShareSource(
                    id: id,
                    name: "\(prefix) \(display.width)×\(display.height)",
                    kind: .display
                )
            }
            if let window = nativeSource as? MacOSWindow {
                let id = "window:\(window.windowID)"
                mappedSources[id] = window
                let application = window.owningApplication?.applicationName ?? "应用"
                let title = window.title?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title?.isEmpty == false
                    ? "\(application) — \(title!)"
                    : application
                return WebRTCScreenShareSource(
                    id: id,
                    name: name,
                    kind: .window
                )
            }
            return nil
        }
        screenSources = mappedSources
        return sources
    }

    public func setScreenShare(
        enabled: Bool,
        sourceID: String? = nil,
        includeSystemAudio: Bool = false
    ) async throws {
        if !enabled {
            if let screenPublication {
                try await room.localParticipant.unpublish(
                    publication: screenPublication
                )
            }
            screenPublication = nil
            systemAudioRequested = false
            try await synchronizeOutgoingAudio()
            return
        }

        guard screenPublication == nil else { return }
        let source: MacOSScreenCaptureSource
        if let sourceID, let selectedSource = screenSources[sourceID] {
            source = selectedSource
        } else {
            source = try await MacOSScreenCapturer.mainDisplaySource()
        }

        systemAudioRequested = includeSystemAudio
        do {
            try await synchronizeOutgoingAudio()
        } catch {
            systemAudioRequested = false
            throw error
        }

        let captureOptions = ScreenShareCaptureOptions(
            dimensions: .h1080_169,
            fps: 30,
            showCursor: true,
            appAudio: includeSystemAudio,
            includeCurrentApplication: true
        )
        let publishOptions = VideoPublishOptions(
            screenShareEncoding: VideoEncoding(maxBitrate: 6_000_000, maxFps: 30),
            simulcast: false,
            preferredCodec: preferredVideoCodec,
            preferredBackupCodec: preferredVideoCodec == .h265 ? .h264 : nil,
            degradationPreference: .maintainResolution
        )
        let track = LocalVideoTrack.createMacOSScreenShareTrack(
            source: source,
            options: captureOptions
        )
        do {
            screenPublication = try await room.localParticipant.publish(
                videoTrack: track,
                options: publishOptions
            )
        } catch {
            systemAudioRequested = false
            try? await synchronizeOutgoingAudio()
            throw error
        }
    }

    private func synchronizeOutgoingAudio() async throws {
        AudioManager.shared.mixer.micVolume = microphoneRequested ? 1 : 0
        AudioManager.shared.mixer.appVolume = systemAudioRequested ? 1 : 0
        let shouldPublish = microphoneRequested || systemAudioRequested
        let captureOptions = AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: true,
            noiseSuppression: true,
            highpassFilter: true
        )
        try await room.localParticipant.setMicrophone(
            enabled: shouldPublish,
            captureOptions: captureOptions
        )
    }

    public func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        switch connectionState {
        case .connecting:
            onStateChange?(.connecting)
        case .reconnecting:
            onStateChange?(.reconnecting)
        case .connected:
            emitConnectedState()
        case .disconnecting:
            break
        case .disconnected:
            onStateChange?(.disconnected)
        }
    }

    public func roomDidConnect(_ room: Room) {
        emitConnectedState()
    }

    public func roomIsReconnecting(_ room: Room) {
        onStateChange?(.reconnecting)
    }

    public func roomDidReconnect(_ room: Room) {
        emitConnectedState()
    }

    public func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        onStateChange?(.failed(error?.localizedDescription ?? "无法连接 WebRTC SFU"))
    }

    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        onRemoteVideoTrack?(nil)
        onParticipantCount?(0)
        if let error {
            onStateChange?(.failed(error.localizedDescription))
        } else {
            onStateChange?(.disconnected)
        }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        emitParticipantCount()
        emitScreenTrack(from: participant)
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        emitParticipantCount()
        if participant.firstScreenShareVideoTrack != nil ||
            isAuxiliaryScreenParticipant(participant) {
            onRemoteVideoTrack?(nil)
        }
    }

    public func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        guard isScreenPublication(publication, from: participant),
              let track = publication.track as? VideoTrack else { return }
        onRemoteVideoTrack?(WebRTCVideoTrackHandle(track: track))
    }

    public func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        guard isScreenPublication(publication, from: participant) else { return }
        onRemoteVideoTrack?(nil)
    }

    private func emitConnectedState() {
        onStateChange?(.connected)
        emitParticipantCount()
        for participant in room.remoteParticipants.values {
            emitScreenTrack(from: participant)
        }
    }

    private func emitParticipantCount() {
        let visibleRemoteCount = room.remoteParticipants.values.filter {
            !isAuxiliaryScreenParticipant($0)
        }.count
        onParticipantCount?(visibleRemoteCount + 1)
    }

    private func emitScreenTrack(from participant: RemoteParticipant) {
        let track: VideoTrack?
        if isAuxiliaryScreenParticipant(participant) {
            track = participant.videoTracks.first(where: {
                $0.isSubscribed && !$0.isMuted
            })?.track as? VideoTrack
        } else {
            track = participant.firstScreenShareVideoTrack
        }
        guard let track else { return }
        onRemoteVideoTrack?(WebRTCVideoTrackHandle(track: track))
    }

    private func isAuxiliaryScreenParticipant(
        _ participant: RemoteParticipant
    ) -> Bool {
        participant.identity?.stringValue == auxiliaryScreenIdentity
    }

    private func isScreenPublication(
        _ publication: RemoteTrackPublication,
        from participant: RemoteParticipant
    ) -> Bool {
        publication.source == .screenShareVideo ||
            isAuxiliaryScreenParticipant(participant)
    }
}
