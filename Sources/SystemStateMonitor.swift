import AppKit
import CoreGraphics

extension Notification.Name {
    /// Posted (on main) when the lock, screen-saver, display or sleep state
    /// changes.
    static let worktimelapsSystemStateChanged = Notification.Name("WorkTimeLaps.systemStateChanged")
}

/// Tracks whether anyone could be working right now: screen unlocked, no
/// screen saver, display awake, Mac awake, and our login session in front.
/// The recorder pauses — no screenshots, no API calls — whenever any of
/// these says no, so an always-on recorder doesn't spend the night
/// uploading pictures of the lock screen.
@MainActor
final class SystemStateMonitor {

    static let shared = SystemStateMonitor()

    private(set) var isScreenLocked = false
    private(set) var isScreenSaverRunning = false
    private(set) var isDisplayAsleep = false
    private(set) var isSystemAsleep = false
    private(set) var isSessionInactive = false

    /// Human-readable reason nobody can be working, or nil if the screen is
    /// available.
    var awayReason: String? {
        if isSystemAsleep { return "Mac asleep" }
        if isSessionInactive { return "another user is active" }
        if isScreenLocked { return "screen locked" }
        if isScreenSaverRunning { return "screen saver" }
        if isDisplayAsleep { return "display asleep" }
        return nil
    }

    private var started = false
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {}

    /// Begins observing. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        isScreenLocked = Self.queryScreenLocked()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.isSystemAsleep = false
            $0.isScreenLocked = Self.queryScreenLocked()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.isDisplayAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionInactive = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isScreenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isScreenLocked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.isScreenSaverRunning = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.isScreenSaverRunning = false }
    }

    private func observe(_ center: NotificationCenter,
                         _ name: Notification.Name,
                         _ update: @escaping @Sendable @MainActor (SystemStateMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                update(SystemStateMonitor.shared)
                NotificationCenter.default.post(name: .worktimelapsSystemStateChanged, object: nil)
            }
        }
        tokens.append((center, token))
    }

    /// Reads the lock state directly. Used at launch and after wake, when no
    /// lock notification arrives for the current state.
    static func queryScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
