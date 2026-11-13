import AppKit
import CoreImage
import CoreVideo

public final class VideoFrameRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func image(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
