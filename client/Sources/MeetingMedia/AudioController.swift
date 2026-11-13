import AudioToolbox
import AVFoundation
import Foundation

public final class AudioController {
    public var onCapturedOpus: ((Data, UInt32) -> Void)?
    public var onDecodedOpus: (() -> Void)?

    private final class DecoderState {
        let converter: AVAudioConverter

        init?(source: AVAudioFormat, destination: AVAudioFormat) {
            guard let converter = AVAudioConverter(from: source, to: destination) else {
                return nil
            }
            self.converter = converter
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "meeting.audio.opus")
    private let mediaFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private let opusFormat: AVAudioFormat
    private var captureConverter: AVAudioConverter?
    private var opusEncoder: AVAudioConverter?
    private var opusDecoders: [UInt32: DecoderState] = [:]
    private var pendingPCM = Data()
    private var microphoneRunning = false
    private var audioTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max)

    public init() {
        opusFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000
        ])!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: mediaFormat)
        player.volume = 1
    }

    public func startPlayback() throws {
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    public func startMicrophone() throws {
        guard !microphoneRunning else { return }
        try startPlayback()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let captureConverter = AVAudioConverter(from: inputFormat, to: mediaFormat),
              let opusEncoder = AVAudioConverter(from: mediaFormat, to: opusFormat) else {
            throw AudioError.unsupportedInputFormat
        }
        opusEncoder.bitRate = 24_000
        self.captureConverter = captureConverter
        self.opusEncoder = opusEncoder
        pendingPCM.removeAll(keepingCapacity: true)

        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) {
            [weak self] buffer, _ in
            self?.convertAndEncode(buffer)
        }
        microphoneRunning = true
    }

    public func stopMicrophone() {
        guard microphoneRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureConverter = nil
        queue.sync {
            opusEncoder = nil
            pendingPCM.removeAll()
        }
        microphoneRunning = false
    }

    public func playOpus(_ data: Data, from ssrc: UInt32) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.decodeAndPlay(data, from: ssrc)
        }
    }

    public func stop() {
        stopMicrophone()
        queue.sync {
            opusDecoders.removeAll()
        }
        player.stop()
        engine.stop()
    }

    private func convertAndEncode(_ inputBuffer: AVAudioPCMBuffer) {
        guard let captureConverter else { return }
        let ratio = mediaFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(inputBuffer.frameLength) * ratio) + 16)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: mediaFormat,
            frameCapacity: capacity
        ) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = captureConverter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.int16ChannelData?.pointee else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let pcm = Data(bytes: channel, count: byteCount)
        queue.async { [weak self] in
            self?.appendAndEncode(pcm)
        }
    }

    private func appendAndEncode(_ pcm: Data) {
        pendingPCM.append(pcm)
        let frameBytes = 960 * MemoryLayout<Int16>.size
        while pendingPCM.count >= frameBytes {
            let frame = Data(pendingPCM.prefix(frameBytes))
            pendingPCM.removeFirst(frameBytes)
            if let encoded = encodeOpus(frame) {
                let timestamp = audioTimestamp
                audioTimestamp &+= 960
                onCapturedOpus?(encoded, timestamp)
            }
        }
    }

    private func encodeOpus(_ pcm: Data) -> Data? {
        guard let opusEncoder,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: mediaFormat,
                frameCapacity: 960
              ),
              let channel = buffer.int16ChannelData?.pointee else { return nil }
        buffer.frameLength = 960
        pcm.copyBytes(
            to: UnsafeMutableRawBufferPointer(start: channel, count: pcm.count)
        )

        let maximumPacketSize = max(1275, Int(opusEncoder.maximumOutputPacketSize))
        let compressed = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: maximumPacketSize
        )
        var suppliedInput = false
        var error: NSError?
        let status = opusEncoder.convert(to: compressed, error: &error) {
            _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error,
              status != .endOfStream,
              error == nil,
              compressed.byteLength > 0 else { return nil }
        return Data(bytes: compressed.data, count: Int(compressed.byteLength))
    }

    private func decodeAndPlay(_ data: Data, from ssrc: UInt32) {
        do {
            try startPlayback()
        } catch {
            return
        }
        let state: DecoderState
        if let existing = opusDecoders[ssrc] {
            state = existing
        } else {
            guard let created = DecoderState(source: opusFormat, destination: mediaFormat) else {
                return
            }
            opusDecoders[ssrc] = created
            state = created
        }

        let compressed = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: max(1275, data.count)
        )
        data.copyBytes(
            to: UnsafeMutableRawBufferPointer(
                start: compressed.data,
                count: data.count
            )
        )
        compressed.byteLength = UInt32(data.count)
        compressed.packetCount = 1
        if let descriptions = compressed.packetDescriptions {
            descriptions.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 960,
                mDataByteSize: UInt32(data.count)
            )
        }

        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: mediaFormat,
            frameCapacity: 5_760
        ) else { return }
        var suppliedInput = false
        var error: NSError?
        let status = state.converter.convert(to: pcm, error: &error) {
            _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return compressed
        }
        guard status != .error,
              status != .endOfStream,
              error == nil,
              pcm.frameLength > 0 else { return }
        player.scheduleBuffer(pcm)
        onDecodedOpus?()
    }
}

public enum AudioError: LocalizedError {
    case unsupportedInputFormat

    public var errorDescription: String? {
        "当前麦克风格式无法转换为 48 kHz Opus"
    }
}
