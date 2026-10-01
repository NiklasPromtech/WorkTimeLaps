import Foundation
import AppKit
import CoreGraphics

/// Snapshot of "what's in the foreground right now" — the frontmost app's
/// bundle id and the title of its frontmost on-screen window. Fed to
/// PrivacyRulesStore.match() once per captured frame to decide whether the
/// image should be redacted before being written to the MP4.
struct WorkContext: Sendable {
    let bundleID: String?
    let appName: String?
    let windowTitle: String?
    /// Where the frontmost window is, in global display coordinates (points,
    /// origin at the top-left of the main display). Picks the screen to
    /// capture when recording follows your focus.
    var windowBounds: CGRect? = nil
}

/// Minimal helper that reads the foreground context. Does *not* use the
/// Accessibility API (which would require a separate TCC prompt). Window
/// titles come via CGWindowList — populated reliably as long as the app
/// already has Screen Recording permission, which WorkTimeLaps does.
enum WorkContextProbe {

    /// Best-effort current context. Returns nils for fields it can't
    /// resolve rather than failing — the rule engine treats nils as
    /// "didn't match" and falls through to the next rule type.
    static func current() -> WorkContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName

        // Windows owned by the frontmost app and visible (layer 0 = normal
        // app windows), front to back: CGWindowList lists windows in
        // z-order, so the first one is the window in front.
        let candidates: [[String: Any]] = {
            guard let pid = app?.processIdentifier else { return [] }
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
            return raw.filter { dict in
                let owner = dict[kCGWindowOwnerPID as String] as? pid_t
                let layer = dict[kCGWindowLayer as String] as? Int ?? 0
                let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
                return owner == pid && layer == 0 && alpha > 0
            }
        }()

        let title = candidates
            .compactMap { $0[kCGWindowName as String] as? String }
            .first { !$0.isEmpty }

        let bounds: CGRect? = candidates.first.flatMap { window in
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict as CFDictionary)
        }

        return WorkContext(bundleID: bundleID, appName: appName, windowTitle: title, windowBounds: bounds)
    }
}
