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

// MARK: - Plan for the day

/// What the morning brief needs to plan the day it's read on.
struct PlanContext: Sendable {
    /// The work day the plan is for.
    let planDayKey: String
    /// Conversations seen on the diary's day, one line per person.
    let conversations: [String]
    let openFollowUps: [FollowUp]
    let closedFollowUps: [FollowUp]
    /// Meetings seen on screen that start on the plan day or the day after.
    let meetings: [MeetingMention]
    /// People talked to in the last two weeks, and about what.
    let recentConversations: [String]
    /// A line per recent work day: its diary headline, or top activities.
    let recentWork: [String]
    /// False when noticing follow-ups and meetings is turned off.
    let includesFollowUps: Bool
}

extension DiaryComposer {

    private static let lookbackDays = 14

    /// Gathers the plan context for the brief written about `material`'s day
    /// and read on `planDayKey`. Reads the last two weeks of frame logs, so
    /// call it off the main thread.
    static func planContext(for material: DayMaterial, planDayKey: String,
                            includeFollowUps: Bool, now: Date = Date()) -> PlanContext {
        let windowStart = now.addingTimeInterval(-Double(lookbackDays + 1) * 86_400)
        let recent = recentFrames(since: windowStart)

        // Meetings on the plan day or the day after, deduplicated by title
        // and start time; the earliest sighting is kept.
        var meetings: [MeetingMention] = []
        if includeFollowUps, let planDay = WorkDay.interval(forKey: planDayKey) {
            let horizon = planDay.end.addingTimeInterval(86_400)
            var seen = Set<String>()
            for frame in recent {
                for m in frame.meetings ?? [] {
                    guard let start = m.startDate, start >= planDay.start, start < horizon else { continue }
                    let key = RecognitionStore.normalizedQuote(m.title) + "|" + m.start
                    if seen.insert(key).inserted { meetings.append(m) }
                }
            }
            meetings.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        }

        // Recent conversations by person (outside the diary's own day).
        var recentConversations: [String] = []
        if includeFollowUps {
            var byPerson: [String: (name: String, topics: [String], last: Date)] = [:]
            for frame in recent where WorkDay.key(for: frame.t) != material.dayKey {
                guard let c = frame.conversation else { continue }
                let key = RecognitionStore.normalizedQuote(c.with)
                var entry = byPerson[key] ?? (c.with, [], frame.t)
                if !c.topic.isEmpty && !entry.topics.contains(c.topic) { entry.topics.append(c.topic) }
                entry.last = max(entry.last, frame.t)
                byPerson[key] = entry
            }
            recentConversations = byPerson.values
                .sorted { $0.last > $1.last }
                .prefix(25)
                .map { "\($0.name) — \($0.topics.suffix(3).joined(separator: "; ")) · last seen \(WorkDay.key(for: $0.last))" }
        }

        return PlanContext(
            planDayKey: planDayKey,
            conversations: includeFollowUps ? conversationLines(material.frames) : [],
            openFollowUps: includeFollowUps ? FollowUpStore.open : [],
            closedFollowUps: includeFollowUps ? FollowUpStore.recentlyClosedByUser(now: now) : [],
            meetings: Array(meetings.prefix(12)),
            recentConversations: recentConversations,
            recentWork: recentWorkLines(before: material.dayKey, frames: recent),
            includesFollowUps: includeFollowUps
        )
    }

    /// Frames from session logs touched in the window, oldest first. Covers
    /// the recording in progress too, whose log isn't in the journal yet.
    private static func recentFrames(since start: Date) -> [FrameEntry] {
        let folder = TimeLapseRecorder.recordingsFolder
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var frames: [FrameEntry] = []
        for url in urls where url.lastPathComponent.hasPrefix("TimeLapse_") && url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (modified ?? .distantPast) >= start, let session = try? SessionWriter.read(from: url) else { continue }
            frames.append(contentsOf: session.frames.filter { $0.t >= start })
        }
        return frames.sorted { $0.t < $1.t }
    }

    /// One line per person talked to in `frames`: when, about what, the
    /// latest request seen, and who wrote last.
    static func conversationLines(_ frames: [FrameEntry]) -> [String] {
        var order: [String] = []
        var groups: [String: [(t: Date, c: ConversationSnapshot)]] = [:]
        for frame in frames {
            guard let c = frame.conversation else { continue }
            let key = RecognitionStore.normalizedQuote(c.with)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((frame.t, c))
        }
        return order.prefix(40).compactMap { key in
            guard let snaps = groups[key], let first = snaps.first, let latest = snaps.last else { return nil }
            var topics: [String] = []
            for s in snaps where !s.c.topic.isEmpty && !topics.contains(s.c.topic) { topics.append(s.c.topic) }
            var line = "\(DiaryFormat.clock(first.t))–\(DiaryFormat.clock(latest.t)) · \(latest.c.with)"
            if let app = latest.c.app { line += " (\(app))" }
            if !topics.isEmpty { line += " — \(topics.suffix(3).joined(separator: "; "))" }
            if let ask = snaps.last(where: { $0.c.hasOpenRequest }) {
                let who = ask.c.requestBy == "me" ? "you asked" : "they asked"
                line += " · request at \(DiaryFormat.clock(ask.t)), \(who): \(ask.c.request ?? "")"
            } else {
                line += " · no open request seen"
            }
            if let from = latest.c.lastFrom {
                line += " · last message from \(from == "me" ? "you" : latest.c.with) (as of \(DiaryFormat.clock(latest.t)))"
            }
            return line
        }
    }

    /// A line per recent work day before `dayKey`: the diary's headline and
    /// highlights when there is one, otherwise the top activities.
    private static func recentWorkLines(before dayKey: String, frames: [FrameEntry]) -> [String] {
        var framesByDay: [String: [FrameEntry]] = [:]
        for frame in frames { framesByDay[WorkDay.key(for: frame.t), default: []].append(frame) }

        var lines: [String] = []
        for offset in 1...lookbackDays {
            guard let key = WorkDay.key(dayKey, offsetBy: -offset) else { continue }
            if let diary = DiaryStore.load(dayKey: key) {
                var line = "\(key) — \(diary.headline)"
                if !diary.highlights.isEmpty { line += ". Highlights: " + diary.highlights.prefix(4).joined(separator: "; ") }
                lines.append(line)
            } else if let dayFrames = framesByDay[key], !dayFrames.isEmpty {
                let blocks = ActivityTimeline.blocks(from: dayFrames, captureInterval: 60).filter { !isPrivate($0) }
                var seconds: [String: Double] = [:]
                for b in blocks { seconds[b.activity, default: 0] += b.activeSeconds }
                let top = seconds.sorted { $0.value > $1.value }.prefix(4)
                    .map { "\($0.key) \(DiaryFormat.duration($0.value))" }
                if !top.isEmpty { lines.append("\(key) — " + top.joined(separator: ", ")) }
            }
        }
        return lines
    }

    /// The plan part of the brief's prompt.
    static func planPromptText(_ context: PlanContext) -> String {
        let planDate = WorkDay.date(fromKey: context.planDayKey).map(DiaryFormat.longDate) ?? context.planDayKey
        var out: [String] = []
        out.append("<plan_day>")
        out.append("Also plan \(planDate): the day the person reads this brief, at 09:00.")
        out.append("</plan_day>")

        func section(_ tag: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out.append("")
            out.append("<\(tag)>")
            out.append(contentsOf: lines)
            out.append("</\(tag)>")
        }

        section("conversations", context.conversations)
        section("open_followups", context.openFollowUps.map { f in
            let side = f.isWaitingOnThem ? "waiting on \(f.with)" : "you owe \(f.with)"
            return "id \(f.id) · \(side): \(f.request) · since \(f.since)"
        })
        section("closed_followups", context.closedFollowUps.map { "\($0.with): \($0.request)" })
        section("upcoming_meetings", context.meetings.map { m in
            let with = (m.with ?? "").isEmpty ? "" : " · with \(m.with!)"
            return "\(m.start.replacingOccurrences(of: "T", with: " ")) · \(m.title)\(with)"
        })
        section("recent_conversations", context.recentConversations)
        section("recent_work", context.recentWork)
        return out.joined(separator: "\n")
    }
}
