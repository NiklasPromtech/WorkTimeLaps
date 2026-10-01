import Foundation
import ServiceManagement

/// Opens WorkTimeLaps at login via `SMAppService`, so recording (and the
/// diary) keeps going across restarts without any manual setup.
///
/// The registration points at the app's current location. Install it in
/// /Applications first — moving the app afterwards breaks the login item
/// until it's toggled again.
@MainActor
enum LoginItem {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// macOS wants the user to approve the item in System Settings.
    static var needsApproval: Bool { status == .requiresApproval }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            AppLog.error("couldn't \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
