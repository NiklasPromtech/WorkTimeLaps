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
/// sheet is built from. Stored append-only in
/// `~/Movies/WorkTimeLaps/_journal/recognitions.json` and *never*
/// pruned. MP4s and per-session sidecars can roll off under the size
/// quota; the recognition log is the long-term receipt store.
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

/// Append-only store for recognitions. Mirrors the shape of `Journal`
/// — file under `_journal/`, atomic writes, JSONEncoder with
/// `.iso8601` dates and pretty/sorted output for diff-friendliness.
enum RecognitionStore {

    /// Lives under `_journal/` so it survives storage-cap pruning. The
    /// journal directory is created on demand by `Journal.folder`.
    static var fileURL: URL {
        Journal.folder.appendingPathComponent("recognitions.json")
    }

    // MARK: - Writing

    /// Append one recognition to disk. Read-modify-write because the
    /// file is small (a year of even prolific recognition is single
    /// digits of MB) and atomic writes are simpler than maintaining
    /// a multi-file index.
    ///
    /// Speaker name is normalized on the way in (trimmed, runs of
    /// internal whitespace collapsed) so trivial dupes from OCR jitter
    /// don't fragment the Top Voices list. We don't try to fuzzy-merge
    /// genuine spelling drift ("Tchuindjang" vs "Tchundjang") here —
    /// that's a future enhancement; for now those would each get their
    /// own row.
    static func append(_ rec: Recognition) {
        var existing = loadAll()
        let cleaned = rec.normalizingSpeaker()
        // Skip duplicates — analyzer can fire repeatedly on the same
        // visible quote across consecutive frames. We dedupe on
        // (sessionID, frameIndex) when both are present, falling back
        // to (capturedAt, quote) otherwise.
        if existing.contains(where: { isSameMoment($0, cleaned) }) {
            return
        }
        existing.append(cleaned)
        do {
            try write(existing)
            postUpdate()
        } catch {
            NSLog("WorkTimeLaps: recognition append failed: \(error.localizedDescription)")
        }
    }

    private static func isSameMoment(_ a: Recognition, _ b: Recognition) -> Bool {
        if let aIdx = a.frameIndex, let bIdx = b.frameIndex,
           let aSes = a.sessionID, let bSes = b.sessionID {
            return aSes == bSes && aIdx == bIdx
        }
        return abs(a.capturedAt.timeIntervalSince(b.capturedAt)) < 1.0
            && a.quote == b.quote
    }

    // MARK: - Reading

    /// Returns every recognition on disk, ordered most recent first.
    /// Cheap as long as the file is reasonable-sized — we'll add
    /// indexing if a power user crosses tens of thousands of entries.
    static func loadAll() -> [Recognition] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let entries = (try? decoder.decode([Recognition].self, from: data)) ?? []
        return entries.sorted(by: { $0.capturedAt > $1.capturedAt })
    }

    /// Recognitions captured within the given closed-open range.
    /// Used by the Highlights view's period selector ("last 30 days",
    /// "this month", custom).
    static func loadInPeriod(from start: Date, to end: Date) -> [Recognition] {
        loadAll().filter { $0.capturedAt >= start && $0.capturedAt < end }
    }

    /// Returns top speakers in the period, sorted by weighted count
    /// (level.weight summed). The top entries are the people whose
    /// quotes you'd put on the brag sheet first.
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

    /// Counts grouped by activity (the tool/task vocabulary) so the
    /// dashboard can answer "which projects produced the most
    /// recognition." Unknown/missing activity is bucketed into
    /// "Other" so it still shows up.
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

    // MARK: - Editing (future-friendly)

    /// Removes a single recognition by id. Used by future "this was
    /// noise, hide it" UI; ships disabled in v1 but the plumbing is
    /// there so we don't have to migrate later.
    @discardableResult
    static func remove(id: String) -> Bool {
        var existing = loadAll()
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

    private static func write(_ entries: [Recognition]) throws {
        // Persist in chronological order so a manual `cat` reads
        // naturally. Sorted-keys + pretty output keeps git diffs sane
        // if anyone backs the folder up to version control.
        let chronological = entries.sorted(by: { $0.capturedAt < $1.capturedAt })
        let data = try encoder.encode(chronological)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func postUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .worktimelapsRecognitionAppended, object: nil)
        }
    }
}
