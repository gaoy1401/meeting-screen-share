import AudioToolbox
import AVFoundation
import Foundation

func opusHead(preSkip: UInt16 = 312) -> Data {
    var data = Data("OpusHead".utf8)
    data.append(contentsOf: [1, 1])
    data.append(UInt8(preSkip & 0xFF))
    data.append(UInt8(preSkip >> 8))
    data.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])
    data.append(contentsOf: [0, 0, 0])
    return data
}

func decode(_ data: Data, cookie: Data?) -> (AVAudioConverterOutputStatus, Int, Error?) {
    let opus = AVAudioFormat(settings: [
        AVFormatIDKey: kAudioFormatOpus,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1
    ])!
    let pcm = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    let converter = AVAudioConverter(from: opus, to: pcm)!
    converter.magicCookie = cookie

    let compressed = AVAudioCompressedBuffer(
        format: opus,
        packetCapacity: 1,
        maximumPacketSize: max(1275, data.count)
    )
    data.copyBytes(
        to: UnsafeMutableRawBufferPointer(start: compressed.data, count: data.count)
    )
    compressed.byteLength = UInt32(data.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 960,
        mDataByteSize: UInt32(data.count)
    )

    let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5_760)!
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if supplied {
            inputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return compressed
    }
    return (status, Int(output.frameLength), error)
}

let path = CommandLine.arguments.dropFirst().first ?? "/tmp/meeting-opus-packet.bin"
let packet = try Data(contentsOf: URL(fileURLWithPath: path))
let withoutCookie = decode(packet, cookie: nil)
let withCookie = decode(packet, cookie: opusHead())

print(
    "Opus packet bytes=\(packet.count) " +
    "withoutCookie=(status:\(withoutCookie.0.rawValue),frames:\(withoutCookie.1)," +
    "error:\(String(describing: withoutCookie.2)))"
)
print(
    "withCookie=(status:\(withCookie.0.rawValue),frames:\(withCookie.1)," +
    "error:\(String(describing: withCookie.2)))"
)
guard withCookie.1 > 0 else {
    fatalError("Apple Opus decoder produced no PCM frames")
}
print("MeetingMedia Opus interoperability check passed")
