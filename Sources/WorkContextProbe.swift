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

        let title: String? = {
            guard let pid = app?.processIdentifier else { return nil }
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }

            // Filter to windows owned by the frontmost app and visible
            // (layer 0 = normal app windows). Pick the one with the lowest
            // window number, which CG uses as a rough z-order proxy — the
            // most-recently-active window sits at the front of the list.
            let candidates = raw.filter { dict in
                let owner = dict[kCGWindowOwnerPID as String] as? pid_t
                let layer = dict[kCGWindowLayer as String] as? Int ?? 0
                let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
                return owner == pid && layer == 0 && alpha > 0
            }
            for c in candidates {
                if let name = c[kCGWindowName as String] as? String, !name.isEmpty {
                    return name
                }
            }
            return nil
        }()

        return WorkContext(bundleID: bundleID, appName: appName, windowTitle: title)
    }
}
