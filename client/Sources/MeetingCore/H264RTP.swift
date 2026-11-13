import Foundation

public final class H264RTPPacketizer {
    public init() {}

    public func packetize(
        accessUnit: Data,
        timestamp: UInt32,
        ssrc: UInt32,
        nextSequence: () -> UInt16
    ) -> [RTPPacket] {
        let nalUnits = Self.splitAnnexB(accessUnit)
        var packets: [RTPPacket] = []

        for (nalIndex, nal) in nalUnits.enumerated() where !nal.isEmpty {
            let isLastNAL = nalIndex == nalUnits.count - 1
            if nal.count <= RTPPacket.maxPayloadSize {
                packets.append(
                    RTPPacket(
                        marker: isLastNAL,
                        payloadType: .h264,
                        sequence: nextSequence(),
                        timestamp: timestamp,
                        ssrc: ssrc,
                        payload: nal
                    )
                )
                continue
            }

            let bytes = [UInt8](nal)
            let nalHeader = bytes[0]
            let fuIndicator = (nalHeader & 0xE0) | 28
            let nalType = nalHeader & 0x1F
            let fragmentSize = RTPPacket.maxPayloadSize - 2
            var offset = 1
            while offset < bytes.count {
                let end = min(offset + fragmentSize, bytes.count)
                let startBit: UInt8 = offset == 1 ? 0x80 : 0
                let endBit: UInt8 = end == bytes.count ? 0x40 : 0
                var payload = Data([fuIndicator, startBit | endBit | nalType])
                payload.append(contentsOf: bytes[offset..<end])
                packets.append(
                    RTPPacket(
                        marker: isLastNAL && end == bytes.count,
                        payloadType: .h264,
                        sequence: nextSequence(),
                        timestamp: timestamp,
                        ssrc: ssrc,
                        payload: payload
                    )
                )
                offset = end
            }
        }
        return packets
    }

    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, prefix: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return data.isEmpty ? [] : [data] }
        return starts.enumerated().compactMap { item, start in
            let payloadStart = start.offset + start.prefix
            let payloadEnd = item + 1 < starts.count ? starts[item + 1].offset : bytes.count
            guard payloadStart < payloadEnd else { return nil }
            return Data(bytes[payloadStart..<payloadEnd])
        }
    }
}

public final class H264RTPDepacketizer {
    private struct PacketKey: Hashable {
        let ssrc: UInt32
        let timestamp: UInt32
        let sequence: UInt16
    }

    private struct StreamState {
        var timestamp: UInt32?
        var expectedSequence: UInt16?
        var accessUnit = Data()
        var fragmentedNAL = Data()
        var damaged = false
    }

    private let lock = NSLock()
    private var streams: [UInt32: StreamState] = [:]
    private var recentPackets: Set<PacketKey> = []
    private var recentPacketOrder: [PacketKey] = []

    public init() {}

    public func ingest(_ packet: RTPPacket) -> Data? {
        guard packet.payloadType == .h264, !packet.payload.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let packetKey = PacketKey(
            ssrc: packet.ssrc,
            timestamp: packet.timestamp,
            sequence: packet.sequence
        )
        if recentPackets.contains(packetKey) {
            return nil
        }
        recentPackets.insert(packetKey)
        recentPacketOrder.append(packetKey)
        if recentPacketOrder.count > 8_192 {
            for expired in recentPacketOrder.prefix(2_048) {
                recentPackets.remove(expired)
            }
            recentPacketOrder.removeFirst(2_048)
        }

        var state = streams[packet.ssrc] ?? StreamState()
        if state.timestamp != packet.timestamp {
            state = StreamState(timestamp: packet.timestamp)
        }
        if let expected = state.expectedSequence, packet.sequence != expected {
            state.damaged = true
            state.fragmentedNAL.removeAll(keepingCapacity: true)
        }
        state.expectedSequence = packet.sequence &+ 1

        let bytes = [UInt8](packet.payload)
        let nalType = bytes[0] & 0x1F
        if nalType == 28, bytes.count >= 3 {
            let fuHeader = bytes[1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            if isStart {
                state.fragmentedNAL = Data([0, 0, 0, 1, (bytes[0] & 0xE0) | (fuHeader & 0x1F)])
                state.fragmentedNAL.append(contentsOf: bytes.dropFirst(2))
            } else if !state.fragmentedNAL.isEmpty {
                state.fragmentedNAL.append(contentsOf: bytes.dropFirst(2))
            } else {
                state.damaged = true
            }
            if isEnd, !state.fragmentedNAL.isEmpty {
                state.accessUnit.append(state.fragmentedNAL)
                state.fragmentedNAL.removeAll(keepingCapacity: true)
            }
        } else if nalType > 0, nalType < 24 {
            state.accessUnit.append(contentsOf: [0, 0, 0, 1])
            state.accessUnit.append(packet.payload)
        } else {
            state.damaged = true
        }

        if packet.marker {
            let result = !state.damaged && state.fragmentedNAL.isEmpty
                ? state.accessUnit
                : nil
            streams[packet.ssrc] = StreamState()
            return result
        }
        streams[packet.ssrc] = state
        return nil
    }

    public func reset() {
        lock.lock()
        streams.removeAll()
        recentPackets.removeAll()
        recentPacketOrder.removeAll()
        lock.unlock()
    }
}
