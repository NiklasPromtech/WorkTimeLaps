import Foundation

/// User preferences that don't belong to a more specific store. Privacy
/// filters, redaction rules, the API key, video retention and the work-day
/// cutoff each keep their own. Everything here is UserDefaults-backed and
/// takes effect immediately.
enum Preferences {

    private enum Key {
        static let autoStart = "WorkTimeLaps.autoStartOnLaunch"
        static let onboarded = "WorkTimeLaps.onboardingCompleted"
        static let diaryHour = "WorkTimeLaps.diaryNotificationHour"
        static let diaryMinute = "WorkTimeLaps.diaryNotificationMinute"
        static let diaryWithClaude = "WorkTimeLaps.writeDiaryWithClaude"
    }

    private static var defaults: UserDefaults { .standard }

    /// Start recording as soon as the app launches. On by default: the app
    /// is meant to run all day so the diary has something to work from.
    static var autoStartRecording: Bool {
        get { defaults.object(forKey: Key.autoStart) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoStart) }
    }

    /// Set once the welcome window has been completed. Recording never
    /// starts automatically before that, so a new user always sees what
    /// gets sent where first.
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    /// When the "your diary is ready" notification arrives, the morning
    /// after each work day. 09:00 by default.
    static var diaryNotificationHour: Int {
        get { (defaults.object(forKey: Key.diaryHour) as? Int).map { min(max($0, 0), 23) } ?? 9 }
        set { defaults.set(min(max(newValue, 0), 23), forKey: Key.diaryHour) }
    }

    static var diaryNotificationMinute: Int {
        get { (defaults.object(forKey: Key.diaryMinute) as? Int).map { min(max($0, 0), 59) } ?? 0 }
        set { defaults.set(min(max(newValue, 0), 59), forKey: Key.diaryMinute) }
    }

    /// Have Claude write the diary entry. When off (or without an API key)
    /// the diary is assembled locally from the day's stats and timeline.
    static var writeDiaryWithClaude: Bool {
        get { defaults.object(forKey: Key.diaryWithClaude) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.diaryWithClaude) }
    }
}
