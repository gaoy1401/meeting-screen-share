import Foundation

public enum RTPPayloadType: UInt8, Sendable {
    case h264 = 96
    case opus = 111
}

public struct RTPPacket: Sendable {
    public static let headerSize = 12
    public static let maxDatagramSize = 1200
    public static let maxPayloadSize = maxDatagramSize - headerSize

    public let marker: Bool
    public let payloadType: RTPPayloadType
    public let sequence: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: Data

    public init(
        marker: Bool,
        payloadType: RTPPayloadType,
        sequence: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }
}

public enum RTPCodecError: Error, LocalizedError {
    case tooShort
    case tooLarge
    case unsupportedVersion
    case unsupportedHeader
    case unknownPayloadType

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "RTP 数据包短于固定头部"
        case .tooLarge: return "RTP 数据包超过 1200 字节"
        case .unsupportedVersion: return "RTP 版本不受支持"
        case .unsupportedHeader: return "暂不支持扩展 RTP 头部"
        case .unknownPayloadType: return "未知的 RTP 负载类型"
        }
    }
}

public enum RTPCodec {
    public static func encode(_ packet: RTPPacket) throws -> Data {
        guard packet.payload.count <= RTPPacket.maxPayloadSize else {
            throw RTPCodecError.tooLarge
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(RTPPacket.headerSize + packet.payload.count)
        bytes.append(0x80)
        bytes.append((packet.marker ? 0x80 : 0) | packet.payloadType.rawValue)
        append(packet.sequence, to: &bytes)
        append(packet.timestamp, to: &bytes)
        append(packet.ssrc, to: &bytes)
        bytes.append(contentsOf: packet.payload)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> RTPPacket {
        guard data.count >= RTPPacket.headerSize else {
            throw RTPCodecError.tooShort
        }
        guard data.count <= RTPPacket.maxDatagramSize else {
            throw RTPCodecError.tooLarge
        }
        let bytes = [UInt8](data)
        guard bytes[0] >> 6 == 2 else {
            throw RTPCodecError.unsupportedVersion
        }
        let hasPadding = (bytes[0] & 0x20) != 0
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        guard !hasPadding, !hasExtension, csrcCount == 0 else {
            throw RTPCodecError.unsupportedHeader
        }
        guard let payloadType = RTPPayloadType(rawValue: bytes[1] & 0x7F) else {
            throw RTPCodecError.unknownPayloadType
        }
        return RTPPacket(
            marker: (bytes[1] & 0x80) != 0,
            payloadType: payloadType,
            sequence: readUInt16(bytes, 2),
            timestamp: readUInt32(bytes, 4),
            ssrc: readUInt32(bytes, 8),
            payload: Data(bytes.dropFirst(RTPPacket.headerSize))
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
        (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) << 8) |
        UInt32(bytes[offset + 3])
    }
}
