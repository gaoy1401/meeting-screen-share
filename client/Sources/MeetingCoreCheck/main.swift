import Foundation
import MeetingCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("MeetingCore check failed: \(message)")
    }
}

let original = MediaPacket(
    type: .screen,
    flags: 7,
    sessionID: 0xfedcba98,
    sequence: 42,
    frameID: 11,
    chunkIndex: 2,
    chunkCount: 5,
    timestampMs: 123_456_789,
    payload: Data("legacy-fragment".utf8)
)

do {
    let decoded = try PacketCodec.decode(PacketCodec.encode(original))
    require(decoded.type == .screen, "packet type")
    require(decoded.flags == 7, "flags")
    require(decoded.sessionID == 0xfedcba98, "session ID")
    require(decoded.sequence == 42, "sequence")
    require(decoded.frameID == 11, "frame ID")
    require(decoded.chunkIndex == 2, "chunk index")
    require(decoded.chunkCount == 5, "chunk count")
    require(decoded.timestampMs == 123_456_789, "timestamp")
    require(decoded.payload == Data("legacy-fragment".utf8), "payload")
} catch {
    fatalError("MeetingCore round-trip failed: \(error)")
}

let oversized = MediaPacket(
    type: .audio,
    sessionID: 1,
    sequence: 1,
    payload: Data(count: MediaPacket.maxPayloadSize + 1)
)
do {
    _ = try PacketCodec.encode(oversized)
    fatalError("MeetingCore accepted an oversized payload")
} catch PacketCodecError.tooLarge {
    // Expected.
} catch {
    fatalError("MeetingCore returned the wrong oversized-payload error: \(error)")
}

print("MeetingCore checks passed")

let rtp = RTPPacket(
    marker: true,
    payloadType: .opus,
    sequence: 65_530,
    timestamp: 123_456,
    ssrc: 0xfedcba98,
    payload: Data([1, 2, 3])
)
do {
    let decoded = try RTPCodec.decode(RTPCodec.encode(rtp))
    require(decoded.marker, "RTP marker")
    require(decoded.payloadType == .opus, "RTP payload type")
    require(decoded.sequence == 65_530, "RTP sequence")
    require(decoded.timestamp == 123_456, "RTP timestamp")
    require(decoded.ssrc == 0xfedcba98, "RTP SSRC")
    require(decoded.payload == Data([1, 2, 3]), "RTP payload")
} catch {
    fatalError("RTP round-trip failed: \(error)")
}

var sequence: UInt16 = 100
var accessUnit = Data([0, 0, 0, 1, 0x67, 1, 2, 3])
accessUnit.append(contentsOf: [0, 0, 0, 1, 0x68, 4, 5])
accessUnit.append(contentsOf: [0, 0, 0, 1, 0x65])
accessUnit.append(Data(repeating: 0x55, count: 4_000))
let packetizer = H264RTPPacketizer()
let packets = packetizer.packetize(
    accessUnit: accessUnit,
    timestamp: 90_000,
    ssrc: 7
) {
    sequence &+= 1
    return sequence
}
require(packets.count > 3, "H264 FU-A fragmentation")
let depacketizer = H264RTPDepacketizer()
var rebuilt: Data?
for packet in packets {
    rebuilt = depacketizer.ingest(packet) ?? rebuilt
    rebuilt = depacketizer.ingest(packet) ?? rebuilt
}
require(rebuilt == accessUnit, "H264 RTP reassembly with duplicate recovery packets")

print("RTP/H264 checks passed")
