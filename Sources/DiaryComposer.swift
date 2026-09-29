import Foundation

/// Everything recorded about one finished work day, loaded from the
/// journal, the session sidecars and the recognition log.
struct DayMaterial: Sendable {
    let dayKey: String
    let interval: DateInterval
    let sessions: [DayLog.SessionDigest]
    let frames: [FrameEntry]
    let captureInterval: TimeInterval
    let blocks: [ActivityBlock]
    let stats: DayStats
    let recognitions: [Recognition]
    let notes: [(start: Date, text: String)]
}

/// Builds the diary's inputs locally: stats, a condensed timeline for the
/// prompt, and a fallback entry for when Claude isn't available.
enum DiaryComposer {

    /// Blocks shorter than this are folded into "brief" lines in the prompt.
    private static let minimumPromptBlockSeconds: TimeInterval = 90

    // MARK: - Loading

    /// Loads a day's material, or nil if nothing was recorded that day.
    static func material(for dayKey: String) -> DayMaterial? {
        guard let interval = WorkDay.interval(forKey: dayKey),
              let log = Journal.load(dayKey: dayKey),
              !log.sessions.isEmpty else { return nil }

        let sessions = log.sessions.sorted { $0.startedAt < $1.startedAt }
        var frames: [FrameEntry] = []
        // A day can mix intervals (the setting changed mid-day). Time is
        // counted from the gaps between frames, so the longest interval is
        // the safe one to use for the whole day.
        var captureInterval: TimeInterval = 0
        for digest in sessions {
            if let full = try? SessionWriter.read(from: Journal.sidecarURL(for: digest)) {
                frames.append(contentsOf: full.frames)
                captureInterval = max(captureInterval, full.captureIntervalSec)
            }
        }
        frames.sort { $0.t < $1.t }
        guard !frames.isEmpty else { return nil }

        let blocks = ActivityTimeline.blocks(from: frames, captureInterval: captureInterval)
        let notes = sessions.compactMap { digest -> (start: Date, text: String)? in
            guard let note = digest.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
            return (digest.startedAt, note)
        }

        return DayMaterial(
            dayKey: dayKey,
            interval: interval,
            sessions: sessions,
            frames: frames,
            captureInterval: captureInterval,
            blocks: blocks,
            stats: stats(frames: frames, blocks: blocks, sessions: sessions.count, captureInterval: captureInterval),
            recognitions: RecognitionStore.load(workDay: dayKey),
            notes: notes
        )
    }

    // MARK: - Stats

    static func stats(frames: [FrameEntry], blocks: [ActivityBlock], sessions: Int, captureInterval: TimeInterval) -> DayStats {
        var byCategory: [String: Double] = [:]
        for (category, seconds) in ActivityTimeline.secondsByCategory(frames, captureInterval: captureInterval) {
            byCategory[category.rawValue] = seconds
        }

        // Group blocks by activity name to find where the time went. Private
        // blocks are left out: their labels can name what the redaction was
        // hiding ("Chase banking"), and they're reported only as a total.
        let visible = blocks.filter { !isPrivate($0) }
        var perActivity: [String: (seconds: Double, categories: [FrameCategory: Double])] = [:]
        for block in visible {
            var entry = perActivity[block.activity] ?? (0, [:])
            entry.seconds += block.activeSeconds
            entry.categories[block.topCategory, default: 0] += block.activeSeconds
            perActivity[block.activity] = entry
        }
        let top = perActivity
            .map { name, value in
                DayStats.ActivityTime(
                    name: name,
                    seconds: value.seconds,
                    category: value.categories.max(by: { $0.value < $1.value })?.key ?? .other
                )
            }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6)

        let longest = visible.max(by: { $0.activeSeconds < $1.activeSeconds })

        return DayStats(
            activeSeconds: ActivityTimeline.activeSeconds(frames, captureInterval: captureInterval),
            firstActivity: frames.first?.t,
            lastActivity: frames.last.map { $0.t.addingTimeInterval(captureInterval) },
            sessions: sessions,
            frames: frames.count,
            redactedFrames: frames.filter { $0.redacted }.count,
            categorySeconds: byCategory,
            topActivities: Array(top),
            longestStretchSeconds: longest?.activeSeconds ?? 0,
            longestStretchActivity: longest?.activity,
            switches: max(0, blocks.count - 1)
        )
    }

    static func quotes(from recognitions: [Recognition]) -> [WorkDiary.Quote] {
        recognitions
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { WorkDiary.Quote(text: $0.quote, speaker: $0.speaker, at: $0.capturedAt, level: $0.level, app: $0.sourceAppName) }
    }

    // MARK: - Prompt log

    /// True when every frame in the block was redacted. Its label may name
    /// exactly what the redaction hides, so it's only ever shown as private.
    static func isPrivate(_ block: ActivityBlock) -> Bool {
        block.redactedCount == block.frameCount
    }

    /// The day as compact text lines, for the model. Short blocks between
    /// longer ones are folded into a single "brief" line, and the threshold
    /// rises until the whole day fits in `maxLines`.
    static func timelineLines(_ blocks: [ActivityBlock], maxLines: Int = 160) -> [String] {
        var threshold = minimumPromptBlockSeconds
        var lines = condense(blocks, threshold: threshold)
        while lines.count > maxLines && threshold < 3600 {
            threshold *= 2
            lines = condense(blocks, threshold: threshold)
        }
        return lines
    }

    private static func condense(_ blocks: [ActivityBlock], threshold: TimeInterval) -> [String] {
        var lines: [String] = []
        var brief: [ActivityBlock] = []

        func flushBrief() {
            guard let first = brief.first, let last = brief.last else { return }
            var names: [String] = []
            for b in brief {
                let name = isPrivate(b) ? "private" : b.activity
                if !names.contains(name) { names.append(name) }
            }
            let listed = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
            lines.append("\(DiaryFormat.clock(first.start))–\(DiaryFormat.clock(last.end)) · brief switches: \(listed)")
            brief.removeAll()
        }

        for block in blocks {
            if block.activeSeconds < threshold {
                brief.append(block)
                continue
            }
            flushBrief()
            var line = "\(DiaryFormat.clock(block.start))–\(DiaryFormat.clock(block.end)) · \(DiaryFormat.duration(block.activeSeconds)) · \(block.topCategory.rawValue) · "
            if isPrivate(block) {
                line += "[private — redacted, details withheld]"
            } else {
                line += block.activity
                let summary = block.representativeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty && summary.caseInsensitiveCompare(block.activity) != .orderedSame {
                    line += " — \(summary)"
                }
                line += " (engagement \(block.meanEngagement))"
            }
            lines.append(line)
        }
        flushBrief()
        return lines
    }

    /// The user message sent to Claude: stats, timeline, recognition, notes.
    static func promptText(for material: DayMaterial) -> String {
        let stats = material.stats
        let dayDate = WorkDay.date(fromKey: material.dayKey) ?? material.interval.start
        var out: [String] = []

        out.append("Write my diary entry for \(DiaryFormat.longDate(dayDate)). My work day runs from \(DiaryFormat.clock(material.interval.start)) to \(DiaryFormat.clock(material.interval.end)), so anything after midnight still belongs to this day.")
        out.append("")

        out.append("<stats>")
        var worked = "Worked: \(DiaryFormat.duration(stats.activeSeconds))"
        if let first = stats.firstActivity, let last = stats.lastActivity {
            worked += " (\(DiaryFormat.clock(first)) → \(DiaryFormat.clock(last)))"
        }
        worked += ", \(stats.sessions) session\(stats.sessions == 1 ? "" : "s")"
        out.append(worked)
        let categories = stats.categoriesByTime
            .filter { $0.seconds >= 60 }
            .map { "\($0.category.rawValue) \(DiaryFormat.duration($0.seconds))" }
        if !categories.isEmpty {
            out.append("By category: " + categories.joined(separator: ", "))
        }
        let activities = stats.topActivities
            .filter { $0.seconds >= 60 }
            .map { "\($0.name) \(DiaryFormat.duration($0.seconds)) (\($0.category.rawValue))" }
        if !activities.isEmpty {
            out.append("Top activities: " + activities.joined(separator: ", "))
        }
        if let longest = stats.longestStretchActivity, stats.longestStretchSeconds >= 600 {
            out.append("Longest uninterrupted stretch: \(DiaryFormat.duration(stats.longestStretchSeconds)) on \(longest)")
        }
        out.append("Activity switches: \(stats.switches)")
        let privateSeconds = material.blocks.filter(isPrivate).reduce(0) { $0 + $1.activeSeconds }
        if privateSeconds >= 60 {
            out.append("Private (redacted) time: \(DiaryFormat.duration(privateSeconds))")
        }
        out.append("</stats>")
        out.append("")

        out.append("<timeline>")
        out.append(contentsOf: timelineLines(material.blocks))
        out.append("</timeline>")

        if !material.recognitions.isEmpty {
            out.append("")
            out.append("<recognition>")
            for r in material.recognitions {
                let who = [r.speaker, r.sourceAppName.map { "via \($0)" }].compactMap { $0 }.joined(separator: " ")
                out.append("\(DiaryFormat.clock(r.capturedAt)) · \(who.isEmpty ? "someone" : who): \"\(r.quote)\"")
            }
            out.append("</recognition>")
        }

        if !material.notes.isEmpty {
            out.append("")
            out.append("<notes>")
            for note in material.notes {
                out.append("Session starting \(DiaryFormat.clock(note.start)): \(note.text)")
            }
            out.append("</notes>")
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Local diary

    /// A diary assembled without Claude: the numbers, the longest stretches
    /// and any recognition, in plain sentences.
    static func localDiary(from material: DayMaterial, note: String?) -> WorkDiary {
        let stats = material.stats
        let top = stats.topActivities.filter { $0.seconds >= 300 }

        let headline: String = {
            guard let first = top.first else {
                return "\(DiaryFormat.duration(stats.activeSeconds)) of recorded work"
            }
            if top.count >= 2 {
                return "\(first.name) and \(top[1].name)"
            }
            return "Mostly \(first.name)"
        }()

        var entry: [String] = []
        var opening = "I worked \(DiaryFormat.duration(stats.activeSeconds))"
        if let first = stats.firstActivity, let last = stats.lastActivity {
            opening += ", from \(DiaryFormat.time(first)) to \(DiaryFormat.time(last))"
        }
        opening += stats.sessions > 1 ? ", across \(stats.sessions) sessions." : "."
        entry.append(opening)

        if !top.isEmpty {
            let parts = top.prefix(3).map { "\($0.name) (\(DiaryFormat.duration($0.seconds)))" }
            let list = parts.count > 1
                ? parts.dropLast().joined(separator: ", ") + " and " + parts.last!
                : parts[0]
            var middle = "Most of the time went to \(list)."
            if let longest = stats.longestStretchActivity, stats.longestStretchSeconds >= 1200 {
                middle += " The longest uninterrupted stretch was \(DiaryFormat.duration(stats.longestStretchSeconds)) on \(longest)."
            }
            entry.append(middle)
        }

        if !material.recognitions.isEmpty {
            let n = material.recognitions.count
            entry.append(n == 1 ? "Someone took the time to say something nice about my work." : "\(n) people took the time to say something nice about my work.")
        }

        var highlights: [String] = []
        if let longest = stats.longestStretchActivity, stats.longestStretchSeconds >= 1200 {
            highlights.append("\(DiaryFormat.duration(stats.longestStretchSeconds)) of focus on \(longest)")
        }
        highlights.append(contentsOf: material.notes.map { $0.text })

        let timeline = material.blocks
            .filter { $0.activeSeconds >= 900 && !isPrivate($0) }
            .prefix(10)
            .map { block in
                WorkDiary.TimelineItem(
                    start: DiaryFormat.clock(block.start),
                    end: DiaryFormat.clock(block.end),
                    title: block.activity,
                    detail: block.representativeSummary,
                    category: block.topCategory
                )
            }

        return WorkDiary(
            dayKey: material.dayKey,
            generatedAt: Date(),
            model: nil,
            headline: headline,
            entry: entry,
            highlights: highlights,
            timeline: Array(timeline),
            looseEnds: [],
            dayShape: nil,
            stats: stats,
            recognition: quotes(from: material.recognitions),
            note: note
        )
    }
}
