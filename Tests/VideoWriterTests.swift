import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum VideoWriterTests {

    /// SplitMix64, so the frames are the same on every run.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Draws a busy, screen-like frame — lots of small high-contrast boxes,
    /// different every time, like screenshots taken minutes apart.
    static func fill(_ buffer: CVPixelBuffer, width: Int, height: Int, rng: inout SeededGenerator) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        ctx.setFillColor(gray: 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<400 {
            ctx.setFillColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                             blue: .random(in: 0...1, using: &rng), alpha: 1)
            ctx.fill(CGRect(x: Int.random(in: 0..<width, using: &rng), y: Int.random(in: 0..<height, using: &rng),
                            width: Int.random(in: 4...300, using: &rng), height: Int.random(in: 2...40, using: &rng)))
        }
    }

    static func run() {
        suite("Video writer")

        // A regression test: with H.264 frame reordering and short movie
        // fragments, the writer failed (-11800 / -16341) a couple of dozen
        // frames in at the 2-minute interval — and recording silently
        // stopped for the rest of the day.
        for interval in Preferences.captureIntervalOptions.map(\.seconds) {
            test("writes 60 screen-like frames at the \(interval)-second setting") {
                let width = 1728, height = 1117
                let url = dataDir.appendingPathComponent("writer-\(interval).mp4")
                try? FileManager.default.removeItem(at: url)
                let parts = try TimeLapseRecorder.makeVideoWriter(
                    url: url, width: width, height: height,
                    captureInterval: TimeInterval(interval), playbackFPS: 10, bitrate: 3_000_000)
                var rng = SeededGenerator(state: UInt64(interval))

                for i in 0..<60 {
                    var buffer: CVPixelBuffer?
                    guard let pool = parts.adaptor.pixelBufferPool,
                          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                          let buffer else { return fail("no pixel buffer at frame \(i)") }
                    fill(buffer, width: width, height: height, rng: &rng)
                    while !parts.input.isReadyForMoreMediaData && parts.writer.status == .writing { usleep(1000) }
                    let appended = parts.adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
                    guard appended, parts.writer.status == .writing else {
                        return fail("writer failed at frame \(i): \(parts.writer.error.map { "\($0)" } ?? "status \(parts.writer.status.rawValue)")")
                    }
                }

                parts.input.markAsFinished()
                let done = DispatchSemaphore(value: 0)
                parts.writer.finishWriting { done.signal() }
                done.wait()
                expect(parts.writer.status == .completed, "finished with status \(parts.writer.status.rawValue)")
            }
        }
    }
}
