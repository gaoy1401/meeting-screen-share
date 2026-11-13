import MeetingCore

final class VideoRTPReorderBuffer {
    var onPacket: ((RTPPacket) -> Void)?

    private struct Stream {
        var expectedSequence: UInt16?
        var packets: [UInt16: RTPPacket] = [:]
    }

    private let maxBufferedPackets: Int
    private var streams: [UInt32: Stream] = [:]

    init(maxBufferedPackets: Int = 512) {
        self.maxBufferedPackets = maxBufferedPackets
    }

    func ingest(_ packet: RTPPacket) {
        var stream = streams[packet.ssrc] ?? Stream()
        if stream.expectedSequence == nil {
            stream.expectedSequence = packet.sequence
        }
        guard let expected = stream.expectedSequence else { return }

        let distance = Int(packet.sequence &- expected)
        guard distance < 0x8000 else {
            return
        }
        stream.packets[packet.sequence] = packet

        if stream.packets.count > maxBufferedPackets,
           stream.packets[expected] == nil,
           let nearest = stream.packets.keys.min(by: {
               Int($0 &- expected) < Int($1 &- expected)
           }) {
            stream.expectedSequence = nearest
        }

        while let next = stream.expectedSequence,
              let ready = stream.packets.removeValue(forKey: next) {
            stream.expectedSequence = next &+ 1
            onPacket?(ready)
        }
        streams[packet.ssrc] = stream
    }

    func reset() {
        streams.removeAll()
    }
}
