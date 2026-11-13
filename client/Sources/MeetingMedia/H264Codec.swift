import CoreMedia
import CoreVideo
import Foundation
import MeetingCore
import VideoToolbox

public final class H264Encoder {
    public var onAccessUnit: ((Data, UInt32, Bool) -> Void)?

    private let queue = DispatchQueue(label: "meeting.h264.encoder")
    private var session: VTCompressionSession?
    private var dimensions: (width: Int32, height: Int32)?

    public init() {}

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.prepare(width: width, height: height)
                guard let session = self.session else { return }
                var flags = VTEncodeInfoFlags()
                let status = VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: presentationTime,
                    duration: .invalid,
                    frameProperties: nil,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: &flags
                )
                if status != noErr {
                    throw H264CodecError.encoder(status)
                }
            } catch {
                return
            }
        }
    }

    public func stop() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            dimensions = nil
        }
    }

    private func prepare(width: Int32, height: Int32) throws {
        if dimensions?.width == width, dimensions?.height == height, session != nil {
            return
        }
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        var newSession: VTCompressionSession?
        let specification = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: h264CompressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw H264CodecError.encoder(status)
        }

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: 6_000_000 as CFNumber
        )
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [750_000, 1] as CFArray
        )
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: 30 as CFNumber
        )
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 30 as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        dimensions = (width, height)
    }

    fileprivate func handle(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let blockBuffer = sampleBuffer.dataBuffer else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyFrame = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var accessUnit = Data()

        if isKeyFrame {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                if status == noErr, let pointer, size > 0 {
                    accessUnit.append(contentsOf: [0, 0, 0, 1])
                    accessUnit.append(Data(bytes: pointer, count: size))
                }
            }
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == noErr else { return }

        let bytes = [UInt8](avcc)
        var offset = 0
        while offset + 4 <= bytes.count {
            let nalLength =
                (Int(bytes[offset]) << 24) |
                (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) |
                Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= bytes.count else { return }
            accessUnit.append(contentsOf: [0, 0, 0, 1])
            accessUnit.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }

        guard !accessUnit.isEmpty else { return }
        let scaled = CMTimeConvertScale(
            sampleBuffer.presentationTimeStamp,
            timescale: 90_000,
            method: .default
        )
        onAccessUnit?(accessUnit, UInt32(truncatingIfNeeded: scaled.value), isKeyFrame)
    }
}

private let h264CompressionCallback: VTCompressionOutputCallback = {
    refcon, _, status, _, sampleBuffer in
    guard status == noErr, let refcon, let sampleBuffer else { return }
    Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        .handle(sampleBuffer: sampleBuffer)
}

public final class H264Decoder {
    public var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "meeting.h264.decoder")
    private let debugEnabled = ProcessInfo.processInfo.environment["MEETING_DEBUG_MEDIA"] == "1"
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var loggedDecodeStatus: Set<OSStatus> = []
    private var accessUnitCount = 0

    public init() {}

    public func decode(_ accessUnit: Data, timestamp: UInt32) {
        queue.async { [weak self] in
            self?.decodeOnQueue(accessUnit, timestamp: timestamp)
        }
    }

    public func reset() {
        queue.sync {
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
            session = nil
            formatDescription = nil
            sps = nil
            pps = nil
            accessUnitCount = 0
            loggedDecodeStatus.removeAll()
        }
    }

    private func decodeOnQueue(_ accessUnit: Data, timestamp: UInt32) {
        let nalUnits = H264RTPPacketizer.splitAnnexB(accessUnit)
        accessUnitCount += 1
        var pictureNALs: [Data] = []
        for nal in nalUnits where !nal.isEmpty {
            switch nal.first! & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: pictureNALs.append(nal)
            }
        }
        if session == nil, accessUnitCount % 30 == 0 {
            let types = nalUnits.compactMap { $0.first.map { $0 & 0x1F } }
            debug(
                "waiting for parameter sets au=\(accessUnitCount) " +
                "hasSPS=\(sps != nil) hasPPS=\(pps != nil) nalTypes=\(types)"
            )
        }
        guard ensureSession(), let session, let formatDescription, !pictureNALs.isEmpty else {
            return
        }

        var avcc = Data()
        for nal in pictureNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }
        let replaceStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            debug("CMSampleBufferCreateReady failed status=\(sampleStatus)")
            return
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 0),
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr, loggedDecodeStatus.insert(decodeStatus).inserted {
            debug("VTDecompressionSessionDecodeFrame failed status=\(decodeStatus) flags=\(infoFlags.rawValue)")
        }
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let spsPointer = spsBytes.bindMemory(to: UInt8.self).baseAddress!
                let ppsPointer = ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                var pointers = [spsPointer, ppsPointer]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            debug(
                "CMVideoFormatDescriptionCreate failed status=\(status) " +
                "sps=\(sps.count) pps=\(pps.count)"
            )
            return false
        }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ] as CFDictionary
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            debug("VTDecompressionSessionCreate failed status=\(createStatus)")
            return false
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        formatDescription = description
        session = newSession
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        debug(
            "decoder session ready width=\(dimensions.width) height=\(dimensions.height) " +
            "sps=\(sps.count) pps=\(pps.count)"
        )
        return true
    }

    fileprivate func handle(
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        pixelBuffer: CVPixelBuffer?
    ) {
        guard status == noErr, let pixelBuffer else {
            debug("decoder callback status=\(status) flags=\(infoFlags.rawValue)")
            return
        }
        onPixelBuffer?(pixelBuffer)
    }

    private func debug(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[h264-decoder] \(message)\n".utf8))
    }
}

private let h264DecompressionCallback: VTDecompressionOutputCallback = {
    refcon, _, status, infoFlags, imageBuffer, _, _ in
    guard let refcon else { return }
    Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
        .handle(status: status, infoFlags: infoFlags, pixelBuffer: imageBuffer)
}

public enum H264CodecError: Error, LocalizedError {
    case encoder(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encoder(let status): return "H.264 编码器错误：\(status)"
        }
    }
}
