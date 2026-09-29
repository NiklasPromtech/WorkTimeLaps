import Foundation

/// How strong a recognition signal we picked up. Drives whether a row
/// shows up at the top of the brag sheet (.major) or further down as
/// supporting evidence (.weak), and lets the dashboard filter to "the
/// strong stuff only" before exporting a one-pager.
///
/// Stored as a raw string so future levels (e.g. `.glowingReview`) slot
/// in without breaking older files.
enum RecognitionLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case none
    case weak       // polite-but-real ("thanks for handling this!")
    case specific   // names the contribution ("the analysis you did saved us a week")
    case major      // unmistakable ("this was outstanding work, exactly what we needed")

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecognitionLevel(rawValue: raw.lowercased()) ?? .none
    }

    var display: String {
        switch self {
        case .none:     return "—"
        case .weak:     return "Mention"
        case .specific: return "Specific praise"
        case .major:    return "Major recognition"
        }
    }

    /// Numeric weight used for sorting and aggregation (e.g. ranking
    /// people who praised you most strongly, not just most often).
    var weight: Int {
        switch self {
        case .none:     return 0
        case .weak:     return 1
        case .specific: return 3
        case .major:    return 5
        }
    }

    static func < (lhs: RecognitionLevel, rhs: RecognitionLevel) -> Bool {
        lhs.weight < rhs.weight
    }
}

/// One captured "moment of recognition" — the atomic record the brag
/// sheet is built from. Stored in `<data folder>/_journal/recognitions.json`
/// and *never* pruned: videos roll off after the retention period, but
/// the recognition log is the long-term receipt store.
///
/// Schema is deliberately conservative — most non-identity fields are
/// optional so the analyzer can return what it can and we don't lose
/// the row over a missing speaker name or activity tag.
struct Recognition: Codable, Sendable, Identifiable {
    /// Stable id (UUID string). Lets later UI edits (rename, hide,
    /// star) target a specific row without relying on timestamps that
    /// might collide on the same frame.
    let id: String

    /// When the recognition was captured. Wall-clock time of the frame
    /// that triggered the detection.
    let capturedAt: Date

    /// How strong the signal was — drives sort order and the "top
    /// recognitions" filter on the dashboard.
    let level: RecognitionLevel

    /// The actual quote, lightly cleaned. Capped at ~280 chars so the
    /// log stays scannable; the analyzer is asked to trim trailing
    /// boilerplate before returning it.
    let quote: String

    /// Best-guess of who said it (extracted by the analyzer from the
    /// frame's chat / email header). May be the empty string if the
    /// frame doesn't show a clear sender.
    let speaker: String?

    /// Bundle id of the frontmost app at capture time. Lets the UI
    /// show a tool icon next to the row and lets the user filter by
    /// channel ("praise that came in over email" vs. Slack DMs).
    let sourceAppBundleID: String?

    /// Friendly display name of the source app (e.g. "Slack", "Gmail").
    let sourceAppName: String?

    /// Activity name the user was on when the recognition came in
    /// — captured straight from the rolling vocabulary so we can
    /// say "the Q2 onboarding rewrite produced 8 distinct positive
    /// signals" rather than just "you got 8 things this month."
    let activity: String?

    /// Frame's resolved category (coding / chat / email / etc.).
    let category: FrameCategory

    /// Reference back to the recording session this came from. Lets
    /// the dashboard offer "watch the moment" if the MP4 is still
    /// around and link a row to its raw context.
    let sessionID: String?

    /// Frame index inside that session, for pinpoint replay.
    let frameIndex: Int64?

    /// Returns a copy with the speaker name trimmed and collapsed —
    /// strips leading/trailing whitespace and reduces any internal
    /// run of whitespace to a single space. Empty strings → nil so
    /// the dashboard skips entries without an attributed speaker.
    func withLevel(_ newLevel: RecognitionLevel) -> Recognition {
        Recognition(
            id: id,
            capturedAt: capturedAt,
            level: newLevel,
            quote: quote,
            speaker: speaker,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            activity: activity,
            category: category,
            sessionID: sessionID,
            frameIndex: frameIndex
        )
    }

    func normalizingSpeaker() -> Recognition {
        guard let raw = speaker else { return self }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalized = collapsed.isEmpty ? nil : collapsed
        return Recognition(
            id: id,
            capturedAt: capturedAt,
            level: level,
            quote: quote,
            speaker: normalized,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            activity: activity,
            category: category,
            sessionID: sessionID,
            frameIndex: frameIndex
        )
    }
}

extension Notification.Name {
    /// Posted (on main) after a Recognition is appended. Highlights
    /// window listens to this to refresh live without polling.
    static let worktimelapsRecognitionAppended = Notification.Name("WorkTimeLaps.recognitionAppended")
}

/// Append-only store for recognitions. File under `_journal/`, atomic
/// writes, ISO-8601 dates, pretty output for diff-friendliness.
enum RecognitionStore {

    /// Lives under `_journal/` so it's never touched by video retention.
    static var fileURL: URL {
        Journal.folder.appendingPathComponent("recognitions.json")
    }

    // MARK: - Writing

    /// Append one recognition. The same compliment usually stays on screen
    /// for several frames (and gets re-read later), so a quote matching one
    /// already captured in the previous 24 hours is merged into it rather
    /// than added again — keeping the stronger level.
    ///
    /// Speaker names are normalized on the way in (trimmed, whitespace
    /// collapsed) so OCR jitter doesn't fragment the Top Voices list.
    static func append(_ rec: Recognition) {
        var existing: [Recognition]
        switch readFile() {
        case .missing:
            existing = []
        case .value(let entries):
            existing = entries
        case .unreadable(let error):
            // Never replace an unreadable history with a one-entry list.
            NSLog("WorkTimeLaps: recognitions.json is unreadable (\(error.localizedDescription))")
            JSONFile.quarantine(fileURL)
            existing = []
        }

        let cleaned = rec.normalizingSpeaker()
        if let idx = existing.firstIndex(where: { isDuplicate($0, cleaned) }) {
            guard cleaned.level > existing[idx].level else { return }
            existing[idx] = existing[idx].withLevel(cleaned.level)
        } else {
            existing.append(cleaned)
        }
        do {
            try write(existing)
            postUpdate()
        } catch {
            NSLog("WorkTimeLaps: recognition append failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Duplicate detection

    /// Lowercased letters, digits and single spaces only.
    static func normalizedQuote(_ s: String) -> String {
        let scalars = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// True when two quotes are the same compliment captured twice: equal
    /// after normalization, one containing the other (the model trimmed a
    /// greeting differently), or at least 80 % word overlap.
    static func isSameQuote(_ a: String, _ b: String) -> Bool {
        let na = normalizedQuote(a)
        let nb = normalizedQuote(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let (shorter, longer) = na.count <= nb.count ? (na, nb) : (nb, na)
        if shorter.count >= 20 && longer.contains(shorter) { return true }
        let wa = Set(na.split(separator: " "))
        let wb = Set(nb.split(separator: " "))
        let union = wa.union(wb).count
        return union > 0 && Double(wa.intersection(wb).count) / Double(union) >= 0.8
    }

    static func isDuplicate(_ a: Recognition, _ b: Recognition) -> Bool {
        abs(a.capturedAt.timeIntervalSince(b.capturedAt)) < 24 * 3600 && isSameQuote(a.quote, b.quote)
    }

    /// Collapses duplicates, keeping the earliest sighting at the strongest
    /// level. Applied on read, so history captured before duplicate
    /// detection existed displays correctly too.
    static func deduplicated(_ entries: [Recognition]) -> [Recognition] {
        var kept: [Recognition] = []
        for rec in entries.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            if let idx = kept.firstIndex(where: { isDuplicate($0, rec) }) {
                if rec.level > kept[idx].level {
                    kept[idx] = kept[idx].withLevel(rec.level)
                }
            } else {
                kept.append(rec)
            }
        }
        return kept
    }

    // MARK: - Reading

    /// Every recognition, deduplicated, most recent first.
    static func loadAll() -> [Recognition] {
        guard case .value(let entries) = readFile() else { return [] }
        return deduplicated(entries).sorted(by: { $0.capturedAt > $1.capturedAt })
    }

    /// Recognitions captured within [start, end).
    static func loadInPeriod(from start: Date, to end: Date) -> [Recognition] {
        loadAll().filter { $0.capturedAt >= start && $0.capturedAt < end }
    }

    /// Recognitions captured during the work day named by `dayKey`.
    static func load(workDay dayKey: String) -> [Recognition] {
        guard let interval = WorkDay.interval(forKey: dayKey) else { return [] }
        return loadInPeriod(from: interval.start, to: interval.end)
            .sorted(by: { $0.capturedAt < $1.capturedAt })
    }

    /// Top speakers in the period, sorted by weighted count (level.weight
    /// summed) — the people you'd quote on the brag sheet first.
    static func topSpeakers(in period: ClosedRange<Date>, limit: Int = 8) -> [(speaker: String, weight: Int, count: Int)] {
        let entries = loadInPeriod(from: period.lowerBound, to: period.upperBound)
        var weighted: [String: (weight: Int, count: Int)] = [:]
        for r in entries {
            guard let s = r.speaker, !s.isEmpty else { continue }
            var current = weighted[s] ?? (0, 0)
            current.weight += r.level.weight
            current.count += 1
            weighted[s] = current
        }
        return weighted
            .map { (speaker: $0.key, weight: $0.value.weight, count: $0.value.count) }
            .sorted(by: { $0.weight > $1.weight })
            .prefix(limit)
            .map { $0 }
    }

    /// Counts grouped by activity, so the dashboard can answer "which
    /// projects produced the most recognition". Missing activity → "Other".
    static func recognitionByActivity(in period: ClosedRange<Date>) -> [(activity: String, weight: Int, count: Int)] {
        let entries = loadInPeriod(from: period.lowerBound, to: period.upperBound)
        var weighted: [String: (weight: Int, count: Int)] = [:]
        for r in entries {
            let key = (r.activity?.isEmpty == false) ? r.activity! : "Other"
            var current = weighted[key] ?? (0, 0)
            current.weight += r.level.weight
            current.count += 1
            weighted[key] = current
        }
        return weighted
            .map { (activity: $0.key, weight: $0.value.weight, count: $0.value.count) }
            .sorted(by: { $0.weight > $1.weight })
    }

    // MARK: - Editing

    /// Removes a single recognition by id (for a future "this was noise"
    /// action).
    @discardableResult
    static func remove(id: String) -> Bool {
        guard case .value(var existing) = readFile() else { return false }
        let before = existing.count
        existing.removeAll { $0.id == id }
        guard existing.count != before else { return false }
        do {
            try write(existing)
            postUpdate()
            return true
        } catch {
            NSLog("WorkTimeLaps: recognition remove failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Disk I/O

    /// Entries that fail to decode are dropped individually rather than
    /// failing the whole file.
    private static func readFile() -> JSONFile.ReadResult<[Recognition]> {
        switch JSONFile.read(LossyArray<Recognition>.self, from: fileURL) {
        case .missing: return .missing
        case .unreadable(let error): return .unreadable(error)
        case .value(let lossy): return .value(lossy.elements)
        }
    }

    /// Persisted in chronological order so a manual `cat` reads naturally.
    private static func write(_ entries: [Recognition]) throws {
        let chronological = entries.sorted(by: { $0.capturedAt < $1.capturedAt })
        try JSONFile.write(chronological, to: fileURL)
    }

    private static func postUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .worktimelapsRecognitionAppended, object: nil)
        }
    }
}
