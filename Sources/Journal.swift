import Foundation

/// Daily rollup of every recording that ended on a given calendar date.
///
/// Lives at `~/Movies/WorkTimeLaps/_journal/YYYY-MM-DD.json` and is the
/// thing we *never* prune — MP4s can roll off under the size quota but the
/// journal stays, so the future reviewer ("you've been working your butt
/// off for X weeks, well done") always has multi-year context to reason
/// over even when the source videos are gone.
///
/// Append-only semantics: each recording's summary is pushed once at stop
/// time. If the app crashes mid-session, the session sidecar is still
/// authoritative — the journal simply won't mention that session until the
/// next clean stop re-summarizes it.
struct DayLog: Codable, Sendable {
    let date: String              // "YYYY-MM-DD" in local time
    var sessions: [SessionDigest]

    struct SessionDigest: Codable, Sendable, Identifiable {
        let id: String
        let video: String
        let startedAt: Date
        let endedAt: Date
        let totalFrames: Int
        let safeFrames: Int
        let redactedFrames: Int
        let averageEngagement: Int
        let topCategory: FrameCategory
        let categoryCounts: [String: Int]

        /// User-authored note attached to this session, added via the Journal
        /// UI after the recording is done. Optional + added late so older
        /// on-disk entries stay decodable.
        var notes: String?

        var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    }
}

extension Notification.Name {
    /// Posted (on the main queue) after Journal has written a day file.
    /// Listened to by JournalStore so open Journal windows refresh.
    static let worktimelapsJournalDidUpdate = Notification.Name("WorkTimeLaps.journalDidUpdate")
}

enum Journal {

    /// Folder holding the per-day journal files. Always exists after first
    /// call; pruning code must preserve it.
    static var folder: URL {
        let root = TimeLapseRecorder.recordingsFolder
        let dir = root.appendingPathComponent("_journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File path for a given date (in local time).
    static func url(for date: Date) -> URL {
        folder.appendingPathComponent("\(dateKey(date)).json")
    }

    /// File path for an already-computed dateKey. Lets callers that already
    /// have "YYYY-MM-DD" strings (e.g. the week grid) skip the re-formatting.
    static func url(forKey key: String) -> URL {
        folder.appendingPathComponent("\(key).json")
    }

    /// Public so the UI layer can derive keys the same way we do on write.
    static func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Append one finished session's digest to the day it ended on.
    /// Read-modify-write; if the file doesn't exist yet we create it.
    static func append(session: RecordingSession) {
        guard let endedAt = session.endedAt, let summary = session.summary else { return }

        let url = url(for: endedAt)
        var log: DayLog
        if let existing = try? read(url: url) {
            log = existing
        } else {
            log = DayLog(date: dateKey(endedAt), sessions: [])
        }

        // Preserve an existing note if the user already added one to a
        // previous copy of this session (e.g. they stopped, noted it, then
        // we reappended for some reason).
        let existingNote = log.sessions.first(where: { $0.id == session.id })?.notes

        let digest = DayLog.SessionDigest(
            id: session.id,
            video: session.video,
            startedAt: session.startedAt,
            endedAt: endedAt,
            totalFrames: summary.totalFrames,
            safeFrames: summary.safeFrames,
            redactedFrames: summary.redactedFrames,
            averageEngagement: summary.averageEngagement,
            topCategory: summary.topCategory,
            categoryCounts: summary.categoryCounts,
            notes: existingNote
        )

        // Replace existing entry with the same id (idempotent re-appends from
        // a re-run stop) rather than duplicating.
        if let idx = log.sessions.firstIndex(where: { $0.id == digest.id }) {
            log.sessions[idx] = digest
        } else {
            log.sessions.append(digest)
        }

        do {
            try write(log: log, to: url)
            postUpdate()
        } catch {
            NSLog("WorkTimeLaps: failed to append journal for \(dateKey(endedAt)): \(error.localizedDescription)")
        }
    }

    // MARK: - Loading (for the Journal UI + future cheerleader)

    /// Returns the day log for a given "YYYY-MM-DD" key, or nil if there's
    /// no file yet. Missing-file is the common case for days with no
    /// recordings — callers treat nil as "empty day."
    static func load(dayKey: String) -> DayLog? {
        let u = url(forKey: dayKey)
        return try? read(url: u)
    }

    /// Loads every day log on disk, sorted newest first. Used by the
    /// cheerleader and by the month-over-month roll-up in the Journal window.
    static func loadAllDays() -> [DayLog] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var logs: [DayLog] = []
        for u in entries where u.pathExtension == "json" {
            if let log = try? read(url: u) {
                logs.append(log)
            }
        }
        // Sort newest first — lexicographic on the date string is correct
        // because of the YYYY-MM-DD format.
        logs.sort { $0.date > $1.date }
        return logs
    }

    /// Updates (or clears) the note on a specific session. Idempotent. Posts
    /// `worktimelapsJournalDidUpdate` so every open Journal view refreshes.
    @discardableResult
    static func setNote(sessionID: String, dayKey: String, note: String?) -> Bool {
        let u = url(forKey: dayKey)
        guard var log = try? read(url: u) else { return false }
        guard let idx = log.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        log.sessions[idx].notes = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try write(log: log, to: u)
            postUpdate()
            return true
        } catch {
            NSLog("WorkTimeLaps: failed to write note for \(sessionID): \(error.localizedDescription)")
            return false
        }
    }

    /// URL of the sidecar JSON (frame-level data) for a given digest. Stored
    /// alongside the MP4 — `<stem>.mp4` / `<stem>.json`.
    static func sidecarURL(for digest: DayLog.SessionDigest) -> URL {
        let stem = (digest.video as NSString).deletingPathExtension
        return TimeLapseRecorder.recordingsFolder.appendingPathComponent("\(stem).json")
    }

    /// URL of the preview thumbnail saved on the first captured frame.
    static func thumbURL(for digest: DayLog.SessionDigest) -> URL {
        let stem = (digest.video as NSString).deletingPathExtension
        return TimeLapseRecorder.recordingsFolder.appendingPathComponent("\(stem).thumb.jpg")
    }

    /// URL of the MP4 itself.
    static func videoURL(for digest: DayLog.SessionDigest) -> URL {
        TimeLapseRecorder.recordingsFolder.appendingPathComponent(digest.video)
    }

    // MARK: - Private

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

    private static func read(url: URL) throws -> DayLog {
        let data = try Data(contentsOf: url)
        return try decoder.decode(DayLog.self, from: data)
    }

    private static func write(log: DayLog, to url: URL) throws {
        let data = try encoder.encode(log)
        try data.write(to: url, options: .atomic)
    }

    private static func postUpdate() {
        // Hop to main so observers (SwiftUI) can republish without warnings.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .worktimelapsJournalDidUpdate, object: nil)
        }
    }
}
