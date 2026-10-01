import AVFoundation
import CoreGraphics
import CoreVideo

/// CVPixelBuffer construction helpers for the writer.
enum PixelBufferHelper {

    /// Render a CGImage into a BGRA CVPixelBuffer, drawing from the writer's
    /// pool when available (saves an allocation per frame).
    static func make(from image: CGImage,
                     width: Int,
                     height: Int,
                     pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?

        if let pool = pool {
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            if status != kCVReturnSuccess { buffer = nil }
        }

        if buffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             width,
                                             height,
                                             kCVPixelFormatType_32BGRA,
                                             attrs as CFDictionary,
                                             &buffer)
            if status != kCVReturnSuccess { return nil }
        }

        guard let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // BGRA memory layout = byteOrder32Little + premultipliedFirst alpha.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return nil }

        // Screens of different sizes share one video: the image is fitted
        // inside the frame without stretching, with black bars around it.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: Screens.aspectFitRect(CGSize(width: image.width, height: image.height),
                                                  in: CGSize(width: width, height: height)))

        return pb
    }
}
