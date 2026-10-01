import Foundation

/// Daily rollup of every recording in one work day (see `WorkDay`).
///
/// Lives at `<data folder>/_journal/YYYY-MM-DD.json` and is never pruned —
/// videos roll off after the retention period, but the journal, session
/// sidecars, diaries and highlights stay.
///
/// Append-only semantics: each recording's summary is pushed when it ends.
/// If the app crashes mid-session, `SessionRecovery` closes the session out
/// on the next launch.
struct DayLog: Codable, Sendable {
    let date: String              // work-day key, "YYYY-MM-DD"
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

        /// User-authored note attached to this session in the Journal.
        /// Optional so older entries stay decodable.
        var notes: String?

        /// Time actually recorded, with absences left out. Optional because
        /// older entries predate it.
        var activeSeconds: Double?

        /// Wall-clock span, first frame to last.
        var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

        /// Best available measure of time worked: the recorded active time,
        /// or frames × the default 10 s interval for older entries.
        var activeDuration: TimeInterval { activeSeconds ?? Double(totalFrames) * 10 }
    }
}

extension Notification.Name {
    /// Posted (on the main queue) after Journal has written a day file.
    /// Listened to by JournalStore so open Journal windows refresh.
    static let worktimelapsJournalDidUpdate = Notification.Name("WorkTimeLaps.journalDidUpdate")
}

enum Journal {

    /// Folder holding the per-day journal files, the rolling activity
    /// vocabulary, recognitions and diaries. Never pruned.
    static var folder: URL {
        let dir = TimeLapseRecorder.recordingsFolder.appendingPathComponent("_journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File for a work-day key ("YYYY-MM-DD").
    static func url(forKey key: String) -> URL {
        folder.appendingPathComponent("\(key).json")
    }

    /// Key for a calendar day as-is. The week grid names each work day by
    /// the calendar date it starts on, so cells use this.
    static func dateKey(_ date: Date) -> String {
        WorkDay.key(forDay: date)
    }

    /// Append one finished session's digest to the work day it started in.
    /// Read-modify-write; replaces an existing entry with the same id.
    static func append(session: RecordingSession) {
        guard let endedAt = session.endedAt, let summary = session.summary else { return }

        let key = WorkDay.key(for: session.startedAt)
        let url = url(forKey: key)
        var log: DayLog
        switch JSONFile.read(DayLog.self, from: url) {
        case .value(let existing):
            log = existing
        case .missing:
            log = DayLog(date: key, sessions: [])
        case .unreadable(let error):
            AppLog.error("day log \(key) is unreadable (\(error.localizedDescription))")
            JSONFile.quarantine(url)
            log = DayLog(date: key, sessions: [])
        }

        // Keep a note the user already attached to this session.
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
            notes: existingNote,
            activeSeconds: summary.activeSeconds
        )

        if let idx = log.sessions.firstIndex(where: { $0.id == digest.id }) {
            log.sessions[idx] = digest
        } else {
            log.sessions.append(digest)
        }
        log.sessions.sort { $0.startedAt < $1.startedAt }

        do {
            try JSONFile.write(log, to: url)
            postUpdate()
        } catch {
            AppLog.error("failed to append journal for \(key): \(error.localizedDescription)")
        }
    }

    // MARK: - Loading

    /// The day log for a work-day key, or nil if there's none (or it can't
    /// be read — the common case is simply a day with no recordings).
    static func load(dayKey: String) -> DayLog? {
        if case .value(let log) = JSONFile.read(DayLog.self, from: url(forKey: dayKey)) {
            return log
        }
        return nil
    }

    /// Every day log on disk, newest first.
    static func loadAllDays() -> [DayLog] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var logs: [DayLog] = []
        for u in entries where u.pathExtension == "json" {
            // Only day files — skip activities.json, recognitions.json, etc.
            guard WorkDay.isKey(u.deletingPathExtension().lastPathComponent) else { continue }
            if case .value(let log) = JSONFile.read(DayLog.self, from: u) {
                logs.append(log)
            }
        }
        logs.sort { $0.date > $1.date }
        return logs
    }

    /// Updates (or clears) the note on a session. Posts
    /// `worktimelapsJournalDidUpdate` so open Journal views refresh.
    @discardableResult
    static func setNote(sessionID: String, dayKey: String, note: String?) -> Bool {
        let u = url(forKey: dayKey)
        guard case .value(var log) = JSONFile.read(DayLog.self, from: u) else { return false }
        guard let idx = log.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        log.sessions[idx].notes = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try JSONFile.write(log, to: u)
            postUpdate()
            return true
        } catch {
            AppLog.error("failed to write note for \(sessionID): \(error.localizedDescription)")
            return false
        }
    }

    /// Time of the newest frame in any session log on disk.
    static func lastRecordedFrameTime() -> Date? {
        let folder = TimeLapseRecorder.recordingsFolder
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let newest = urls
            .filter { $0.lastPathComponent.hasPrefix("TimeLapse_") && $0.pathExtension == "json" }
            .max { modified($0) < modified($1) }
        guard let newest, let session = try? SessionWriter.read(from: newest) else { return nil }
        return session.frames.last?.t
    }

    /// Sidecar JSON (frame-level data) for a digest: `<stem>.json`.
    static func sidecarURL(for digest: DayLog.SessionDigest) -> URL {
        let stem = (digest.video as NSString).deletingPathExtension
        return TimeLapseRecorder.recordingsFolder.appendingPathComponent("\(stem).json")
    }

    /// Preview thumbnail saved from the session's first unredacted frame.
    static func thumbURL(for digest: DayLog.SessionDigest) -> URL {
        let stem = (digest.video as NSString).deletingPathExtension
        return TimeLapseRecorder.recordingsFolder.appendingPathComponent("\(stem).thumb.jpg")
    }

    /// The MP4 itself. May no longer exist once the retention period passes.
    static func videoURL(for digest: DayLog.SessionDigest) -> URL {
        TimeLapseRecorder.recordingsFolder.appendingPathComponent(digest.video)
    }

    private static func postUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .worktimelapsJournalDidUpdate, object: nil)
        }
    }
}

/// Closes out sessions that never finished — the app crashed, the Mac lost
/// power, or it was force-quit — so they still count in the journal and the
/// diary. Run at launch, before recording starts.
enum SessionRecovery {

    /// Returns the number of sessions recovered. `activeSessionID` is
    /// skipped (it's the one being recorded right now).
    @discardableResult
    static func recoverUnfinishedSessions(excluding activeSessionID: String? = nil) -> Int {
        let folder = TimeLapseRecorder.recordingsFolder
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return 0
        }

        var recovered = 0
        for url in contents where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("TimeLapse_") {
            guard var session = try? SessionWriter.read(from: url),
                  session.endedAt == nil,
                  session.id != activeSessionID else { continue }

            guard let last = session.frames.last else {
                // Nothing was ever recorded: drop the empty shell.
                try? fm.removeItem(at: url)
                let video = folder.appendingPathComponent(session.video)
                if let size = (try? video.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 64 * 1024 {
                    try? fm.removeItem(at: video)
                }
                continue
            }

            session.endedAt = last.t.addingTimeInterval(session.captureIntervalSec)
            session.summary = SessionSummary.make(frames: session.frames, captureInterval: session.captureIntervalSec)
            do {
                try SessionWriter.write(session, to: url)
                Journal.append(session: session)
                recovered += 1
                AppLog.notice("recovered unfinished session \(session.id) (\(session.frames.count) frames)")
            } catch {
                AppLog.error("couldn't recover \(session.id): \(error.localizedDescription)")
            }
        }
        return recovered
    }
}
