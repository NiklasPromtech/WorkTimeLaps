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
        static let captureInterval = "WorkTimeLaps.captureIntervalSeconds"
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

    // MARK: - Capture interval

    static let captureIntervalOptions: [(label: String, seconds: Int)] = [
        ("10 sec", 10),
        ("30 sec", 30),
        ("1 min", 60),
        ("2 min", 120)
    ]

    /// Seconds between screenshots. Once a minute by default: enough to see
    /// the shape of a day, at about a sixth of the API cost of every 10 s.
    /// A change takes effect within one interval and starts a new session.
    static var captureIntervalSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.captureInterval)
            return captureIntervalOptions.contains(where: { $0.seconds == stored }) ? stored : 60
        }
        set { defaults.set(newValue, forKey: Key.captureInterval) }
    }

    /// Estimated API cost of one analyzed screenshot: ~1,600 image tokens
    /// plus ~2,000 prompt tokens in at $1 per million, ~150 tokens out at $5
    /// per million (Claude Haiku 4.5 list prices).
    static let estimatedCostPerScreenshot = 0.0044

    /// Estimated API cost of eight active hours at `intervalSeconds`.
    static func estimatedCostPerWorkDay(intervalSeconds: Int) -> Double {
        8 * 3600 / Double(max(intervalSeconds, 1)) * estimatedCostPerScreenshot
    }
}
