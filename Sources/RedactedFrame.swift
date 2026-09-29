import Cocoa
import CoreGraphics

/// Generates a near-black "REDACTED" placeholder CGImage the same size as the
/// real screenshot. Used when SafetyChecker flags a frame (or fails closed).
///
/// Rendering a CGImage each frame would be wasteful — the redaction image
/// doesn't depend on the screenshot contents, only on its dimensions. We
/// cache the last one produced and reuse it while the resolution is stable.
///
/// @MainActor because Cocoa text rendering (NSAttributedString.draw,
/// NSImage.lockFocus) is not thread-safe, and callers can hop to main briefly
/// to grab a frame.
@MainActor
enum RedactedFrame {

    private struct CacheEntry {
        let width: Int
        let height: Int
        let image: CGImage
    }

    private static var cached: CacheEntry?

    /// Returns a CGImage of the given size with a dark background and centered
    /// "REDACTED" text. Safe to call every frame — it's O(1) after the first
    /// call at a given resolution.
    static func image(width: Int, height: Int) -> CGImage? {
        if let c = cached, c.width == width, c.height == height {
            return c.image
        }

        let size = NSSize(width: width, height: height)
        let nsImage = NSImage(size: size)
        nsImage.lockFocus()
        defer { nsImage.unlockFocus() }

        // Background — not pure black so the viewer can tell it's intentional
        // and not a "my video is broken" frame.
        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Font size scales with the shorter side so the text reads on both
        // tiny laptop screens and huge external displays.
        let fontSize = max(24, CGFloat(min(width, height)) * 0.08)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let title = NSAttributedString(
            string: "REDACTED",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.25, alpha: 1.0),
                .paragraphStyle: paragraph,
                .kern: fontSize * 0.15
            ]
        )

        let subtitleFont = NSFont.systemFont(ofSize: fontSize * 0.35, weight: .regular)
        let subtitle = NSAttributedString(
            string: "WorkTimeLaps hid this frame because it looked like it contained a secret.",
            attributes: [
                .font: subtitleFont,
                .foregroundColor: NSColor(white: 0.7, alpha: 1.0),
                .paragraphStyle: paragraph
            ]
        )

        let titleSize = title.size()
        let subtitleSize = subtitle.size()
        let gap: CGFloat = fontSize * 0.4
        let totalHeight = titleSize.height + gap + subtitleSize.height
        let titleY = (CGFloat(height) - totalHeight) / 2 + subtitleSize.height + gap
        let subtitleY = (CGFloat(height) - totalHeight) / 2

        let titleRect = NSRect(x: 0, y: titleY, width: CGFloat(width), height: titleSize.height)
        let subtitleRect = NSRect(x: 0, y: subtitleY, width: CGFloat(width), height: subtitleSize.height)

        title.draw(in: titleRect)
        subtitle.draw(in: subtitleRect)

        // Convert NSImage → CGImage so the writer pipeline can treat it
        // identically to a real screenshot.
        var rect = NSRect(origin: .zero, size: size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        cached = CacheEntry(width: width, height: height, image: cg)
        return cg
    }

    /// Drop the cache — e.g., if the display resolution changes mid-recording
    /// we don't want to keep a stale image around.
    static func invalidate() {
        cached = nil
    }
}
