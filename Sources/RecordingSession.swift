import Foundation

/// On-disk sidecar for a single recording. Written next to the MP4 as
/// `<stem>.json` and rewritten atomically after every frame so a crash or
/// power loss during a multi-hour session still leaves a readable record of
/// what was captured up to that point.
///
/// Keep the schema additive — older sidecars must stay decodable as the
/// reviewer tooling evolves. That's why almost every non-identity field
/// outside `frames` is optional.
struct RecordingSession: Codable, Sendable {

    /// Stable identifier. Shared across `video`, the sidecar JSON, and the
    /// day-journal entry that references this recording.
    let id: String

    /// Filename (not full path) of the MP4 this sidecar describes. Keeps the
    /// JSON portable — move the folder, the pairing still holds.
    let video: String

    let startedAt: Date
    var endedAt: Date?

    /// Updated in-place each time we append a frame, so a crashed session
    /// still has a meaningful "last heard from" timestamp on disk.
    var lastUpdated: Date

    let captureIntervalSec: Double
    let playbackFPS: Int

    struct DisplaySize: Codable, Sendable {
        let width: Int
        let height: Int
    }
    let display: DisplaySize

    var frames: [FrameEntry] = []

    /// Populated once at stop time. Gives reviewers a fast summary without
    /// walking the full `frames` array.
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

    /// Filled only when `redacted == true`. e.g. "secret visible" vs.
    /// "analyzer failed: network". Lets the reviewer tell a genuine leak
    /// flag from an outage-driven fail-closed.
    let redactionReason: String?

    /// If the previous capture was >3× the configured interval ago we mark
    /// the gap here and force engagement to 0. Distinguishes "user was idle"
    /// from "laptop was asleep" when skimming sessions later.
    let sleepGapSec: Double?

    /// Granular, free-text activity label drawn from the rolling 2-hour
    /// vocabulary. Drives the activity-stream view in the Journal.
    /// Optional + added late so older sidecars from before Phase 9 still
    /// decode; missing → "" → activity-stream falls back to category.
    var activity: String?
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
}

/// Atomic, crash-safe writer for `RecordingSession` sidecars.
///
/// Uses `.atomic` writes (write-to-tempfile + rename) so the on-disk JSON
/// is never observed half-written, even if the process is killed mid-write.
/// Called after every frame append, so it has to be cheap — the sessions
/// we care about are ~hundreds to low thousands of frames long, so
/// rewriting the whole blob each time is still under a millisecond.
enum SessionWriter {

    /// Shared encoder. ISO-8601 dates are human-readable in the JSON and
    /// round-trip correctly; sorted + pretty output makes git-diffs and
    /// manual inspection usable.
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

    static func write(_ session: RecordingSession, to url: URL) throws {
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: url)
        return try decoder.decode(RecordingSession.self, from: data)
    }
}
