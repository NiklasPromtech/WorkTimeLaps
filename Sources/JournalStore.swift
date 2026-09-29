import Foundation
import SwiftUI

/// Central read path for everything journal-related. Owns a cached list of
/// day logs loaded from `_journal/*.json`, observes the recorder for live
/// updates, and exposes derivations (week grid cells, day detail) used by
/// both the Journal window and — eventually — the cheerleader reviewer in
/// Phase 9. Keeping this in one place means we add features or migrate the
/// schema once rather than in two places.
@MainActor
final class JournalStore: ObservableObject {

    static let shared = JournalStore()

    /// Loaded day logs, newest first.
    @Published private(set) var days: [DayLog] = []

    /// Weak reference to the live recorder, set by MenuBarController when
    /// the Journal window is opened. Allows the store to surface the
    /// currently-recording session in today's cell without taking ownership
    /// of the recorder.
    weak var recorder: TimeLapseRecorder?

    private var observers: [NSObjectProtocol] = []

    private init() {
        reload()

        // Observe updates from three sources:
        //  1. Journal writes (new sessions ended, or notes edited)
        //  2. Frame appended (live session totals change)
        //  3. Session completed (belt-and-suspenders; Journal.append will
        //     also post journalDidUpdate)
        //
        // The observer closures must be @Sendable (strict concurrency),
        // so we avoid capturing `self` and reach the singleton inside a
        // MainActor Task instead.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .worktimelapsJournalDidUpdate, object: nil, queue: .main) { _ in
            Task { @MainActor in JournalStore.shared.reload() }
        })
        observers.append(center.addObserver(forName: .worktimelapsFrameAppended, object: nil, queue: .main) { _ in
            Task { @MainActor in JournalStore.shared.objectWillChange.send() }
        })
        observers.append(center.addObserver(forName: .worktimelapsSessionCompleted, object: nil, queue: .main) { _ in
            Task { @MainActor in JournalStore.shared.reload() }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Loading

    /// Re-reads every day file from disk. Cheap (JSON is small) so we just
    /// do it on every relevant notification rather than trying to patch the
    /// cache in place.
    func reload() {
        days = Journal.loadAllDays()
    }

    // MARK: - Week grid

    /// One cell in the week grid — either a past day (sessions from disk) or
    /// today, which can additionally carry a live snapshot of a
    /// currently-running recording.
    struct DayCell: Identifiable {
        let id: String           // dateKey, e.g. "2026-04-24"
        let date: Date           // local noon of the day — for sorting/format
        let dateKey: String
        let isToday: Bool
        let sessions: [DayLog.SessionDigest]
        let live: LiveSessionSnapshot?

        /// Completed-session time plus the live session's elapsed time, if any.
        var totalDuration: TimeInterval {
            let completed = sessions.reduce(0.0) { $0 + $1.duration }
            if let live = live {
                return completed + Date().timeIntervalSince(live.startedAt)
            }
            return completed
        }

        var totalFrames: Int {
            sessions.reduce(0) { $0 + $1.totalFrames } + (live?.totalFrames ?? 0)
        }

        var redactedFrames: Int {
            sessions.reduce(0) { $0 + $1.redactedFrames } + (live?.redactedFrames ?? 0)
        }

        /// Weighted-by-frames mean of per-session averages. Rough but fine
        /// for a one-glance number on a week-grid tile.
        var averageEngagement: Int {
            let frames = sessions.reduce(0) { $0 + $1.totalFrames }
            guard frames > 0 else { return live?.engagement ?? 0 }
            let weighted = sessions.reduce(0.0) {
                $0 + Double($1.averageEngagement) * Double($1.totalFrames)
            }
            return Int((weighted / Double(frames)).rounded())
        }

        /// Category with the most frames across all sessions in the day.
        /// Nil means nothing recorded (or only a live session with no
        /// category yet).
        var topCategory: FrameCategory? {
            var counts: [FrameCategory: Int] = [:]
            for s in sessions {
                counts[s.topCategory, default: 0] += s.totalFrames
            }
            return counts.max(by: { $0.value < $1.value })?.key ?? live?.topCategory
        }

        var hasAnyContent: Bool { !sessions.isEmpty || live != nil }
    }

    /// Builds the 7-cell strip for a given week. `anchor` can be any day
    /// inside the week you want displayed; we snap to Monday as the first
    /// column (standard for work-week thinking).
    func weekCells(containing anchor: Date) -> [DayCell] {
        let cal = Calendar.current
        var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
        components.weekday = cal.firstWeekday
        guard let weekStart = cal.date(from: components) else { return [] }

        return (0..<7).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return cell(for: day)
        }
    }

    /// Builds a single day's cell. Use this for "today" tiles in other
    /// views, not just the week grid.
    func cell(for date: Date) -> DayCell {
        let key = Journal.dateKey(date)
        let log = days.first(where: { $0.date == key })
        let todayKey = Journal.dateKey(Date())
        let isToday = key == todayKey

        let live: LiveSessionSnapshot? = {
            guard isToday, let r = recorder, let snap = r.liveSnapshot else { return nil }
            // Only include the live session if it actually started today.
            return Journal.dateKey(snap.startedAt) == todayKey ? snap : nil
        }()

        let noonOfDay = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date

        return DayCell(
            id: key,
            date: noonOfDay,
            dateKey: key,
            isToday: isToday,
            sessions: log?.sessions.sorted(by: { $0.startedAt < $1.startedAt }) ?? [],
            live: live
        )
    }

    // MARK: - Day detail

    /// Frame-level data for one session. Loaded lazily when the user drills
    /// into a session — we don't preload all sidecars because a busy user's
    /// _journal/ folder can reference dozens of MB of sidecar JSON.
    func loadFullSession(for digest: DayLog.SessionDigest) -> RecordingSession? {
        try? SessionWriter.read(from: Journal.sidecarURL(for: digest))
    }

    // MARK: - Note editing

    /// Proxy to Journal.setNote. On success, the journalDidUpdate
    /// notification triggers our own reload, so views update automatically.
    func setNote(for digest: DayLog.SessionDigest, dayKey: String, note: String?) {
        _ = Journal.setNote(sessionID: digest.id, dayKey: dayKey, note: note)
    }
}
