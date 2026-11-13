import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public final class ScreenShareController: NSObject, SCStreamOutput {
    public var onCapturedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let captureQueue = DispatchQueue(label: "meeting.screen.capture")
    private var stream: SCStream?

    public func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw ScreenShareError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(
            1.0,
            min(
                1920.0 / Double(display.width),
                1080.0 / Double(display.height)
            )
        )
        configuration.width = max(2, Int(Double(display.width) * scale))
        configuration.height = max(2, Int(Double(display.height) * scale))
        configuration.width -= configuration.width % 2
        configuration.height -= configuration.height % 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onCapturedFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }
}

public enum ScreenShareError: LocalizedError {
    case noDisplay

    public var errorDescription: String? {
        "没有找到可以共享的显示器"
    }
}
