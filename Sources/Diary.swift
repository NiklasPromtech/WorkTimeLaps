import Foundation

extension Notification.Name {
    /// Posted (on main) when a diary entry is written, or a write starts or
    /// fails.
    static let worktimelapsDiaryUpdated = Notification.Name("WorkTimeLaps.diaryUpdated")
}

/// One work day's diary entry: a short first-person account of the day plus
/// the numbers behind it. Written by Claude from the day's text log (never
/// from screenshots), or assembled locally when there's no API key.
///
/// Stored at `<data folder>/_journal/diary/<day>.json`, with a Markdown copy
/// (`<day>.md`) that opens in any editor.
struct WorkDiary: Codable, Sendable, Identifiable {
    var id: String { dayKey }

    let dayKey: String
    let generatedAt: Date
    /// Model that wrote the entry, or nil for a locally assembled one.
    let model: String?
    let headline: String
    let entry: [String]
    let highlights: [String]
    let timeline: [TimelineItem]
    let looseEnds: [String]
    let dayShape: DayShape?
    let stats: DayStats
    let recognition: [Quote]
    /// Why Claude couldn't write this entry, for a local fallback.
    let note: String?

    var isWrittenByClaude: Bool { model != nil }

    struct TimelineItem: Codable, Sendable, Hashable {
        let start: String   // "HH:mm"
        let end: String
        let title: String
        let detail: String
        let category: FrameCategory
    }

    struct Quote: Codable, Sendable, Hashable {
        let text: String
        let speaker: String?
        let at: Date
        let level: RecognitionLevel
        let app: String?
    }

    enum DayShape: String, Codable, Sendable, CaseIterable {
        case deepFocus = "deep_focus"
        case steady
        case collaborative
        case scattered
        case light

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = DayShape(rawValue: raw) ?? .steady
        }

        var label: String {
            switch self {
            case .deepFocus:     return "Deep focus"
            case .steady:        return "Steady"
            case .collaborative: return "Collaborative"
            case .scattered:     return "Scattered"
            case .light:         return "Light day"
            }
        }

        var symbol: String {
            switch self {
            case .deepFocus:     return "scope"
            case .steady:        return "metronome"
            case .collaborative: return "person.2.fill"
            case .scattered:     return "sparkles"
            case .light:         return "leaf.fill"
            }
        }
    }
}

/// Numbers for one work day, computed locally from the frame log.
struct DayStats: Codable, Sendable {
    let activeSeconds: Double
    let firstActivity: Date?
    let lastActivity: Date?
    let sessions: Int
    let frames: Int
    let redactedFrames: Int
    /// FrameCategory raw value → seconds.
    let categorySeconds: [String: Double]
    let topActivities: [ActivityTime]
    let longestStretchSeconds: Double
    let longestStretchActivity: String?
    /// Number of times the activity changed.
    let switches: Int

    struct ActivityTime: Codable, Sendable, Hashable {
        let name: String
        let seconds: Double
        let category: FrameCategory
    }

    /// Categories sorted by time, largest first.
    var categoriesByTime: [(category: FrameCategory, seconds: Double)] {
        categorySeconds
            .map { (FrameCategory(rawValue: $0.key) ?? .other, $0.value) }
            .sorted { $0.1 > $1.1 }
    }
}

/// Retry and notification bookkeeping for each day's diary.
struct DiaryStatus: Codable, Sendable {
    var attempts: Int = 0
    var lastAttempt: Date?
    var lastError: String?
    /// When the "diary is ready" notification was (or will be) delivered.
    var notificationDeliverAt: Date?
}

/// Reads and writes diary entries under `_journal/diary/`.
enum DiaryStore {

    static var folder: URL {
        let dir = Journal.folder.appendingPathComponent("diary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(dayKey: String) -> URL {
        folder.appendingPathComponent("\(dayKey).json")
    }

    static func markdownURL(dayKey: String) -> URL {
        folder.appendingPathComponent("\(dayKey).md")
    }

    static func exists(dayKey: String) -> Bool {
        FileManager.default.fileExists(atPath: url(dayKey: dayKey).path)
    }

    static func load(dayKey: String) -> WorkDiary? {
        if case .value(let diary) = JSONFile.read(WorkDiary.self, from: url(dayKey: dayKey)) {
            return diary
        }
        return nil
    }

    /// Saves the entry and its Markdown copy. An existing file that can't be
    /// read is moved aside rather than overwritten.
    static func save(_ diary: WorkDiary) throws {
        let jsonURL = url(dayKey: diary.dayKey)
        if case .unreadable = JSONFile.read(WorkDiary.self, from: jsonURL) {
            JSONFile.quarantine(jsonURL)
        }
        try JSONFile.write(diary, to: jsonURL)
        try markdown(for: diary).write(to: markdownURL(dayKey: diary.dayKey), atomically: true, encoding: .utf8)
        postUpdate()
    }

    // MARK: - Status

    private static var statusURL: URL {
        folder.appendingPathComponent("status.json")
    }

    static func status(for dayKey: String) -> DiaryStatus {
        allStatuses()[dayKey] ?? DiaryStatus()
    }

    static func updateStatus(for dayKey: String, _ mutate: (inout DiaryStatus) -> Void) {
        var all = allStatuses()
        var entry = all[dayKey] ?? DiaryStatus()
        mutate(&entry)
        all[dayKey] = entry
        // Bookkeeping only matters for recent days.
        if all.count > 60 {
            let keep = Set(all.keys.sorted().suffix(60))
            all = all.filter { keep.contains($0.key) }
        }
        try? JSONFile.write(all, to: statusURL)
    }

    private static func allStatuses() -> [String: DiaryStatus] {
        if case .value(let all) = JSONFile.read([String: DiaryStatus].self, from: statusURL) {
            return all
        }
        return [:]
    }

    static func postUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .worktimelapsDiaryUpdated, object: nil)
        }
    }

    // MARK: - Markdown

    static func markdown(for diary: WorkDiary) -> String {
        var lines: [String] = []
        let date = WorkDay.date(fromKey: diary.dayKey).map(DiaryFormat.longDate) ?? diary.dayKey
        lines.append("# \(date) — \(diary.headline)")
        lines.append("")

        var facts = ["\(DiaryFormat.duration(diary.stats.activeSeconds)) worked"]
        if let first = diary.stats.firstActivity, let last = diary.stats.lastActivity {
            facts.append("\(DiaryFormat.time(first))–\(DiaryFormat.time(last))")
        }
        if let shape = diary.dayShape { facts.append(shape.label) }
        lines.append("*" + facts.joined(separator: " · ") + "*")
        lines.append("")

        for paragraph in diary.entry {
            lines.append(paragraph)
            lines.append("")
        }

        if !diary.highlights.isEmpty {
            lines.append("## Highlights")
            lines.append(contentsOf: diary.highlights.map { "- \($0)" })
            lines.append("")
        }

        if !diary.timeline.isEmpty {
            lines.append("## Timeline")
            for item in diary.timeline {
                let detail = item.detail.isEmpty ? "" : " — \(item.detail)"
                lines.append("- **\(item.start)–\(item.end)** \(item.title)\(detail)")
            }
            lines.append("")
        }

        if !diary.recognition.isEmpty {
            lines.append("## Recognition")
            for quote in diary.recognition {
                let who = quote.speaker.map { " — \($0)" } ?? ""
                lines.append("> \(quote.text)\(who)")
                lines.append("")
            }
        }

        if !diary.looseEnds.isEmpty {
            lines.append("## Loose ends")
            lines.append(contentsOf: diary.looseEnds.map { "- [ ] \($0)" })
            lines.append("")
        }

        let byCategory = diary.stats.categoriesByTime
            .prefix(6)
            .map { "\($0.category.display) \(DiaryFormat.duration($0.seconds))" }
        if !byCategory.isEmpty {
            lines.append("## Where the time went")
            lines.append(byCategory.joined(separator: " · "))
            lines.append("")
        }

        let author = diary.model.map { "Written by \(DiaryFormat.modelName($0))" } ?? "Assembled locally by WorkTimeLaps"
        lines.append("---")
        lines.append("*\(author) on \(DiaryFormat.timestamp(diary.generatedAt)).*")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Formatting shared by the diary view, Markdown export and notifications.
enum DiaryFormat {

    /// "3h 12m", "42m", "under a minute".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return seconds > 0 ? "under a minute" : "0m" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 24-hour "09:12", used in prompts and timeline entries.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Localized short time ("9:12 AM" or "09:12").
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "Tuesday, September 29, 2026".
    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return f.string(from: date)
    }

    /// "Tue, Sep 29".
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "claude-opus-5-5" → "Claude Opus 5.5".
    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).filter { $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? "Claude \(family)" : "Claude \(family) \(version)"
    }
}
