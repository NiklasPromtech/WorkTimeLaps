import AppKit
import CoreGraphics

/// Which screen to capture, what to call it, and how screens of different
/// sizes share one video.
enum Screens {

    struct Info: Sendable {
        let id: CGDirectDisplayID
        let name: String
        /// Global display coordinates: points, origin at the top-left of the
        /// main display (the same space as window bounds).
        let bounds: CGRect
    }

    // MARK: - Focus

    /// The display that shows most of `window`; failing that, the one under
    /// the mouse pointer; failing that, the main display.
    static func focusedDisplay(window: CGRect?, mouse: CGPoint?,
                               displays: [CGDirectDisplayID: CGRect],
                               main: CGDirectDisplayID) -> CGDirectDisplayID {
        if let window, !window.isEmpty {
            var best: (id: CGDirectDisplayID, area: CGFloat)?
            for (id, bounds) in displays {
                let overlap = bounds.intersection(window)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (id, area) }
            }
            if let best { return best.id }
        }
        if let mouse, let hit = displays.first(where: { $0.value.contains(mouse) }) {
            return hit.key
        }
        return displays[main] != nil ? main : (displays.keys.min() ?? main)
    }

    /// Every active display and where it is.
    static func activeDisplays() -> [CGDirectDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        var result: [CGDirectDisplayID: CGRect] = [:]
        for id in ids.prefix(Int(count)) { result[id] = CGDisplayBounds(id) }
        return result
    }

    /// The mouse pointer in global display coordinates.
    static var mouseLocation: CGPoint? {
        CGEvent(source: nil)?.location
    }

    // MARK: - Names

    /// Names for the menu. Identical models get their position relative to
    /// the main display ("S17 (left)", "S17 (right)").
    static func displayNames(_ screens: [Info], main: CGDirectDisplayID) -> [CGDirectDisplayID: String] {
        let mainBounds = screens.first { $0.id == main }?.bounds ?? .zero
        var counts: [String: Int] = [:]
        for s in screens { counts[s.name, default: 0] += 1 }

        var result: [CGDirectDisplayID: String] = [:]
        var used: [String: Int] = [:]
        for s in screens.sorted(by: { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }) {
            guard counts[s.name, default: 0] > 1 else {
                result[s.id] = s.name
                continue
            }
            let position: String
            if s.id == main { position = "main" }
            else if s.bounds.midX < mainBounds.minX { position = "left" }
            else if s.bounds.midX > mainBounds.maxX { position = "right" }
            else if s.bounds.midY < mainBounds.minY { position = "above" }
            else { position = "below" }
            let label = "\(s.name) (\(position))"
            used[label, default: 0] += 1
            result[s.id] = used[label]! > 1 ? "\(s.name) (\(position) \(used[label]!))" : label
        }
        return result
    }

    /// Names of the screens connected right now.
    @MainActor
    static func currentNames() -> [CGDirectDisplayID: String] {
        let screens = NSScreen.screens.compactMap { screen -> Info? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return Info(id: id, name: screen.localizedName, bounds: CGDisplayBounds(id))
        }
        return displayNames(screens, main: CGMainDisplayID())
    }

    // MARK: - One video for screens of different sizes

    /// A video frame every display fits in: the largest width and the largest
    /// height, rounded up to even numbers for the encoder.
    static func canvasSize(for sizes: [CGSize]) -> (width: Int, height: Int) {
        let width = Int(sizes.map(\.width).max() ?? 1280)
        let height = Int(sizes.map(\.height).max() ?? 800)
        return (width + width % 2, height + height % 2)
    }

    /// Where an image of `size` goes inside `canvas` so it fits without being
    /// stretched, centered with bars on the remaining sides.
    static func aspectFitRect(_ size: CGSize, in canvas: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let scale = min(canvas.width / size.width, canvas.height / size.height)
        let fitted = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return CGRect(x: ((canvas.width - fitted.width) / 2).rounded(),
                      y: ((canvas.height - fitted.height) / 2).rounded(),
                      width: fitted.width, height: fitted.height)
    }
}
