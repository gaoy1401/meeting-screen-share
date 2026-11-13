import Foundation

public enum MediaPacketType: UInt8, Sendable {
    case control = 1
    case audio = 2
    case screen = 3
}

public struct MediaPacket: Sendable {
    public static let headerSize = 32
    public static let maxDatagramSize = 1200
    public static let maxPayloadSize = maxDatagramSize - headerSize

    public let type: MediaPacketType
    public let flags: UInt16
    public let sessionID: UInt32
    public let sequence: UInt32
    public let frameID: UInt32
    public let chunkIndex: UInt16
    public let chunkCount: UInt16
    public let timestampMs: UInt64
    public let payload: Data

    public init(
        type: MediaPacketType,
        flags: UInt16 = 0,
        sessionID: UInt32,
        sequence: UInt32,
        frameID: UInt32 = 0,
        chunkIndex: UInt16 = 0,
        chunkCount: UInt16 = 0,
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        payload: Data
    ) {
        self.type = type
        self.flags = flags
        self.sessionID = sessionID
        self.sequence = sequence
        self.frameID = frameID
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.timestampMs = timestampMs
        self.payload = payload
    }
}

public enum PacketCodecError: Error, LocalizedError {
    case tooShort
    case tooLarge
    case invalidMagic
    case unsupportedVersion
    case unknownType
    case invalidScreenChunk

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "数据包短于固定头部"
        case .tooLarge: return "数据包超过 1200 字节"
        case .invalidMagic: return "数据包标识不正确"
        case .unsupportedVersion: return "协议版本不受支持"
        case .unknownType: return "未知的数据包类型"
        case .invalidScreenChunk: return "屏幕分片元数据不正确"
        }
    }
}

public enum PacketCodec {
    private static let magic: [UInt8] = Array("MSH1".utf8)
    private static let version: UInt8 = 1

    public static func encode(_ packet: MediaPacket) throws -> Data {
        guard packet.payload.count <= MediaPacket.maxPayloadSize else {
            throw PacketCodecError.tooLarge
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(MediaPacket.headerSize + packet.payload.count)
        bytes.append(contentsOf: magic)
        bytes.append(version)
        bytes.append(packet.type.rawValue)
        append(packet.flags, to: &bytes)
        append(packet.sessionID, to: &bytes)
        append(packet.sequence, to: &bytes)
        append(packet.frameID, to: &bytes)
        append(packet.chunkIndex, to: &bytes)
        append(packet.chunkCount, to: &bytes)
        append(packet.timestampMs, to: &bytes)
        bytes.append(contentsOf: packet.payload)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> MediaPacket {
        guard data.count >= MediaPacket.headerSize else {
            throw PacketCodecError.tooShort
        }
        guard data.count <= MediaPacket.maxDatagramSize else {
            throw PacketCodecError.tooLarge
        }

        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else {
            throw PacketCodecError.invalidMagic
        }
        guard bytes[4] == version else {
            throw PacketCodecError.unsupportedVersion
        }
        guard let type = MediaPacketType(rawValue: bytes[5]) else {
            throw PacketCodecError.unknownType
        }

        let packet = MediaPacket(
            type: type,
            flags: readUInt16(bytes, 6),
            sessionID: readUInt32(bytes, 8),
            sequence: readUInt32(bytes, 12),
            frameID: readUInt32(bytes, 16),
            chunkIndex: readUInt16(bytes, 20),
            chunkCount: readUInt16(bytes, 22),
            timestampMs: readUInt64(bytes, 24),
            payload: Data(bytes.dropFirst(MediaPacket.headerSize))
        )

        if type == .screen &&
            (packet.chunkCount == 0 || packet.chunkIndex >= packet.chunkCount) {
            throw PacketCodecError.invalidScreenChunk
        }
        return packet
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { bytes.append(contentsOf: $0) }
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

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in offset..<(offset + 8) {
            result = (result << 8) | UInt64(bytes[index])
        }
        return result
    }
}

