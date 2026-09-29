import Foundation

/// On-disk sidecar for a single recording. Written next to the MP4 as
/// `<stem>.json`, rewritten atomically about once a minute while recording
/// and again when the session ends, so a crash or power loss still leaves a
/// readable record of what was captured.
///
/// Keep the schema additive — older sidecars must stay decodable. That's
/// why almost every non-identity field outside `frames` is optional.
struct RecordingSession: Codable, Sendable {

    /// Stable identifier. Shared across `video`, the sidecar JSON, and the
    /// day-journal entry that references this recording.
    let id: String

    /// Filename (not full path) of the MP4 this sidecar describes. Keeps the
    /// JSON portable — move the folder, the pairing still holds. The MP4
    /// itself is deleted after the video retention period; the sidecar stays.
    let video: String

    let startedAt: Date
    var endedAt: Date?

    /// Updated whenever the sidecar is written, so a crashed session still
    /// has a meaningful "last heard from" timestamp on disk.
    var lastUpdated: Date

    let captureIntervalSec: Double
    let playbackFPS: Int

    struct DisplaySize: Codable, Sendable {
        let width: Int
        let height: Int
    }
    let display: DisplaySize

    var frames: [FrameEntry] = []

    /// Populated when the session ends. Gives readers a fast summary
    /// without walking the full `frames` array.
    var summary: SessionSummary?
}

/// One captured frame. `engagement` is the raw 0-100 the model returned;
/// `engagementSmoothed` is the EMA value at the moment this frame was
/// appended — stored so the UI's "rev meter" can be reconstructed without
/// replaying the smoothing pass.
struct FrameEntry: Codable, Sendable {
    let i: Int64
    let t: Date
    let category: FrameCategory
    let summary: String
    let engagement: Int
    let engagementSmoothed: Int
    let redacted: Bool

    /// Filled only when `redacted == true`: "secret visible",
    /// "privacy:financial", "blocked:app:<bundle id>", "blocked:self" or
    /// "analyzer failed: …". Tells a genuine leak flag from a user rule
    /// or an outage-driven fail-closed.
    let redactionReason: String?

    /// Set when the previous frame was long enough ago that the user was
    /// away (Mac asleep, screen locked, recording paused). Engagement is
    /// forced to 0 on such a frame.
    let sleepGapSec: Double?

    /// Granular, free-text activity label drawn from the rolling 2-hour
    /// vocabulary. Optional because older sidecars predate it; readers fall
    /// back to the category name.
    var activity: String?

    /// A work conversation visible in this frame, if any.
    var conversation: ConversationSnapshot? = nil

    /// Upcoming meetings visible in this frame, if any.
    var meetings: [MeetingMention]? = nil
}

/// End-of-session rollup. `categoryCounts` is `[String: Int]` because
/// JSONEncoder won't cleanly encode enum-typed dictionary keys; the keys
/// are `FrameCategory.rawValue` strings.
struct SessionSummary: Codable, Sendable {
    let totalFrames: Int
    let safeFrames: Int
    let redactedFrames: Int
    let averageEngagement: Int
    let topCategory: FrameCategory
    let categoryCounts: [String: Int]

    /// Time actually spent recording, with absences left out. Optional
    /// because older sidecars predate it.
    var activeSeconds: Double?

    static func make(frames: [FrameEntry], captureInterval: TimeInterval) -> SessionSummary {
        let total = frames.count
        let redacted = frames.filter { $0.redacted }.count

        var counts: [String: Int] = [:]
        var engagementSum = 0
        for f in frames {
            counts[f.category.rawValue, default: 0] += 1
            engagementSum += f.engagementSmoothed
        }
        let avg = total == 0 ? 0 : Int((Double(engagementSum) / Double(total)).rounded())
        let top = counts.max(by: { $0.value < $1.value })?.key ?? FrameCategory.other.rawValue

        return SessionSummary(
            totalFrames: total,
            safeFrames: total - redacted,
            redactedFrames: redacted,
            averageEngagement: avg,
            topCategory: FrameCategory(rawValue: top) ?? .other,
            categoryCounts: counts,
            activeSeconds: ActivityTimeline.activeSeconds(frames, captureInterval: captureInterval)
        )
    }
}

/// Atomic, crash-safe reader/writer for `RecordingSession` sidecars.
///
/// `.atomic` writes (temp file + rename) mean the JSON is never observed
/// half-written. Output is compact because a full day's sidecar runs to
/// a few MB and is rewritten repeatedly while recording.
enum SessionWriter {

    static func write(_ session: RecordingSession, to url: URL) throws {
        try JSONFile.write(session, to: url, encoder: JSONFile.compactEncoder)
    }

    static func read(from url: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: url)
        return try JSONFile.decoder.decode(RecordingSession.self, from: data)
    }
}
