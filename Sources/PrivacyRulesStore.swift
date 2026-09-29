import Foundation
import AppKit

/// What a rule matches against — either the frontmost app's bundle
/// identifier (exact match) or a substring inside the frontmost window's
/// title (case-insensitive). The list is intentionally short; we'd rather
/// add a new rule kind only when there's a clear use case it can't be
/// expressed with these two.
enum PrivacyRuleKind: String, Codable, Sendable, CaseIterable {
    case app           // bundle id, exact match
    case windowTitle   // case-insensitive substring of the window title

    var display: String {
        switch self {
        case .app:         return "App"
        case .windowTitle: return "Window title"
        }
    }
}

/// One blocklist entry. Frames captured while the rule matches the current
/// foreground context are never sent to Claude and are written to the
/// video as a REDACTED placeholder. The frame is still logged — with a
/// category guessed from the rule and the category name as its summary —
/// so daily totals like "X% of the day chatting" stay accurate without any
/// content leaving the Mac or landing in the log.
struct PrivacyRule: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var kind: PrivacyRuleKind
    var pattern: String
    var label: String
    var enabled: Bool

    init(id: UUID = UUID(),
         kind: PrivacyRuleKind,
         pattern: String,
         label: String,
         enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.label = label
        self.enabled = enabled
    }
}

/// UserDefaults-backed persistence for the rule list. Modeled the same way
/// as PrivacyFilterStore — first-launch seeding via a version key, simple
/// add/remove/update primitives, and a `match(...)` evaluator the recorder
/// calls once per frame.
enum PrivacyRulesStore {

    private static let storageKey = "WorkTimeLaps.privacyRules"
    private static let versionKey = "WorkTimeLaps.privacyRulesVersion"
    private static let currentDefaultsVersion = 1

    // MARK: - Defaults

    /// Rules shipped on first launch. Conservative — covers the obvious
    /// "personal apps" plus the spreadsheet category since spreadsheets
    /// (own or client) are usually the worst-case leak vector.
    static let defaultRules: [PrivacyRule] = [
        PrivacyRule(kind: .app, pattern: "com.apple.MobileSMS",            label: "Messages"),
        PrivacyRule(kind: .app, pattern: "org.whispersystems.signal-desktop", label: "Signal"),
        PrivacyRule(kind: .app, pattern: "ru.keepcoder.Telegram",          label: "Telegram"),
        PrivacyRule(kind: .app, pattern: "org.telegram.desktop",           label: "Telegram (alt bundle)"),
        PrivacyRule(kind: .app, pattern: "net.whatsapp.WhatsApp",          label: "WhatsApp"),
        PrivacyRule(kind: .app, pattern: "com.apple.FaceTime",             label: "FaceTime"),
        PrivacyRule(kind: .app, pattern: "com.hnc.Discord",                label: "Discord"),
        PrivacyRule(kind: .app, pattern: "com.apple.iWork.Numbers",        label: "Numbers"),
        PrivacyRule(kind: .app, pattern: "com.microsoft.Excel",            label: "Excel"),
        PrivacyRule(kind: .windowTitle, pattern: "google sheets",          label: "Google Sheets (window title)"),
        PrivacyRule(kind: .windowTitle, pattern: "excel online",           label: "Excel Online (window title)")
    ]

    /// Seed defaults on first launch. Idempotent on subsequent launches.
    /// Bumping `currentDefaultsVersion` will re-seed for users who already
    /// have an older version recorded — useful if we ever decide to add a
    /// new "obvious" default that should reach existing installs too.
    static func ensureDefaults() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        if stored >= currentDefaultsVersion { return }

        // Don't blow away custom rules — only seed if storage is empty.
        if UserDefaults.standard.data(forKey: storageKey) == nil {
            saveRaw(defaultRules)
        }
        UserDefaults.standard.set(currentDefaultsVersion, forKey: versionKey)
    }

    // MARK: - Public API

    static var rules: [PrivacyRule] {
        ensureDefaults()
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PrivacyRule].self, from: data)) ?? []
    }

    static func setRules(_ rules: [PrivacyRule]) {
        saveRaw(rules)
    }

    static func add(_ rule: PrivacyRule) {
        var current = rules
        current.append(rule)
        saveRaw(current)
    }

    static func update(_ rule: PrivacyRule) {
        var current = rules
        if let idx = current.firstIndex(where: { $0.id == rule.id }) {
            current[idx] = rule
            saveRaw(current)
        }
    }

    static func remove(id: UUID) {
        let current = rules.filter { $0.id != id }
        saveRaw(current)
    }

    /// Returns the first enabled rule that matches the supplied context, or
    /// nil if no rule fires. Walks rules in their stored order so the user
    /// has a way to express priority if they want it (drag-reorder later).
    static func match(bundleID: String?, windowTitle: String?) -> PrivacyRule? {
        for rule in rules where rule.enabled {
            switch rule.kind {
            case .app:
                if let id = bundleID, id == rule.pattern { return rule }
            case .windowTitle:
                if let title = windowTitle,
                   title.range(of: rule.pattern, options: .caseInsensitive) != nil {
                    return rule
                }
            }
        }
        return nil
    }

    /// Category logged for frames a rule blocks. Blocked frames never reach
    /// the analyzer, so this is what keeps an hour in Signal counted as chat
    /// time in the journal and the diary.
    static func category(for rule: PrivacyRule) -> FrameCategory {
        switch rule.pattern.lowercased() {
        case "com.apple.mobilesms",
             "org.whispersystems.signal-desktop",
             "ru.keepcoder.telegram",
             "org.telegram.desktop",
             "net.whatsapp.whatsapp",
             "com.hnc.discord",
             "com.tinyspeck.slackmacgap",
             "com.microsoft.teams2":
            return .chat
        case "com.apple.facetime", "us.zoom.xos":
            return .meeting
        case "com.apple.mail", "com.microsoft.outlook":
            return .email
        default:
            return .other
        }
    }

    // MARK: - Private

    private static func saveRaw(_ rules: [PrivacyRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
