import AppKit
import Foundation
import MeetingCore

public final class RTPMediaReceiver {
    public var onImage: ((NSImage) -> Void)?
    public var onDecodedOpus: (() -> Void)?

    private let queue = DispatchQueue(label: "meeting.media.receiver")
    private let audio: AudioController
    private let audioJitter = AudioJitterBuffer()
    private let videoReorder = VideoRTPReorderBuffer()
    private let h264Depacketizer = H264RTPDepacketizer()
    private let h264Decoder = H264Decoder()
    private let renderer = VideoFrameRenderer()
    private let debugEnabled = ProcessInfo.processInfo.environment["MEETING_DEBUG_MEDIA"] == "1"
    private var videoPackets = 0
    private var completedAccessUnits = 0
    private var droppedAccessUnits = 0
    private var decodedFrames = 0
    private var audioPackets = 0
    private var lastDebugAt = Date()

    public init(audio: AudioController) {
        self.audio = audio
        audioJitter.onPayload = { [weak audio] ssrc, payload in
            audio?.playOpus(payload, from: ssrc)
        }
        audio.onDecodedOpus = { [weak self] in
            self?.onDecodedOpus?()
        }
        videoReorder.onPacket = { [weak self] packet in
            self?.ingestOrderedVideo(packet)
        }
        h264Decoder.onPixelBuffer = { [weak self] pixelBuffer in
            guard let self, let image = self.renderer.image(from: pixelBuffer) else {
                return
            }
            self.queue.async {
                self.decodedFrames += 1
                self.printDebugIfNeeded()
            }
            self.onImage?(image)
        }
    }

    public func ingest(_ packet: RTPPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            switch packet.payloadType {
            case .opus:
                self.audioPackets += 1
                self.audioJitter.ingest(packet)
            case .h264:
                self.videoPackets += 1
                self.videoReorder.ingest(packet)
            }
            self.printDebugIfNeeded()
        }
    }

    public func reset() {
        queue.sync {
            h264Depacketizer.reset()
            videoReorder.reset()
            h264Decoder.reset()
            audioJitter.reset()
            videoPackets = 0
            completedAccessUnits = 0
            droppedAccessUnits = 0
            decodedFrames = 0
            audioPackets = 0
            lastDebugAt = Date()
        }
    }

    private func ingestOrderedVideo(_ packet: RTPPacket) {
        let accessUnit = h264Depacketizer.ingest(packet)
        if let accessUnit {
            completedAccessUnits += 1
            h264Decoder.decode(accessUnit, timestamp: packet.timestamp)
        } else if packet.marker {
            droppedAccessUnits += 1
        }
    }

    private func printDebugIfNeeded() {
        guard debugEnabled, Date().timeIntervalSince(lastDebugAt) >= 5 else { return }
        let line =
            "[media-recv] videoPackets=\(videoPackets) " +
            "completeAU=\(completedAccessUnits) droppedAU=\(droppedAccessUnits) " +
            "decodedFrames=\(decodedFrames) audioPackets=\(audioPackets)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lastDebugAt = Date()
    }
}
