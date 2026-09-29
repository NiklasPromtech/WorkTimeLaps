import Foundation

/// One run of consecutive frames that share an activity label. Shared by the
/// Journal's activity stream and the diary's timeline.
struct ActivityBlock: Identifiable, Sendable {
    let id: Int64
    let activity: String
    let representativeSummary: String
    let start: Date
    let end: Date
    let frameCount: Int
    let redactedCount: Int
    let meanEngagement: Int
    let topCategory: FrameCategory
    /// Time actually spent in the block: frames × capture interval, with
    /// long gaps (lock screen, sleep, pause) left out.
    let activeSeconds: TimeInterval
    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

/// Turns a frame log into activity blocks and active time. No UI, no I/O.
enum ActivityTimeline {

    /// A gap between two frames longer than this means the user was away
    /// (screen locked, Mac asleep, recording paused). It splits blocks and
    /// isn't counted as working time. Generous enough that a slow analyzer
    /// call (30 s timeout) never looks like an absence.
    static func gapThreshold(for captureInterval: TimeInterval) -> TimeInterval {
        max(captureInterval * 3, captureInterval + 35)
    }

    /// Seconds of activity represented by `frames`. Each frame accounts for
    /// the time until the next one (capped at two intervals); a frame
    /// followed by an absence, and the final frame, count one interval.
    static func activeSeconds(_ frames: [FrameEntry], captureInterval: TimeInterval) -> TimeInterval {
        guard !frames.isEmpty else { return 0 }
        let threshold = gapThreshold(for: captureInterval)
        var total: TimeInterval = 0
        for i in frames.indices {
            if i + 1 < frames.count {
                let gap = frames[i + 1].t.timeIntervalSince(frames[i].t)
                if gap > 0 && gap <= threshold {
                    total += min(gap, captureInterval * 2)
                } else {
                    total += captureInterval
                }
            } else {
                total += captureInterval
            }
        }
        return total
    }

    /// Activity label for a frame, falling back to the category name for
    /// frames that predate activity labels or failed validation.
    static func activityName(_ frame: FrameEntry) -> String {
        let raw = (frame.activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? frame.category.display : raw
    }

    /// Clusters consecutive frames with the same activity (case-insensitive)
    /// into blocks. A long gap always starts a new block, so a lunch break
    /// never shows up as one two-hour block of "Slack".
    static func blocks(from frames: [FrameEntry], captureInterval: TimeInterval) -> [ActivityBlock] {
        guard !frames.isEmpty else { return [] }
        let threshold = gapThreshold(for: captureInterval)
        func key(_ f: FrameEntry) -> String { activityName(f).lowercased() }

        var blocks: [ActivityBlock] = []
        var startIdx = 0
        for i in 1...frames.count {
            let endHere = i == frames.count
                || key(frames[i]) != key(frames[startIdx])
                || frames[i].t.timeIntervalSince(frames[i - 1].t) > threshold
            guard endHere else { continue }

            let slice = Array(frames[startIdx..<i])
            let first = slice[0]
            let last = slice[slice.count - 1]

            // Most common summary in the run; first frame's as a fallback.
            var summaryCounts: [String: Int] = [:]
            for f in slice where !f.summary.isEmpty {
                summaryCounts[f.summary, default: 0] += 1
            }
            let representative = summaryCounts.max(by: { $0.value < $1.value })?.key ?? first.summary

            var catCounts: [FrameCategory: Int] = [:]
            for f in slice { catCounts[f.category, default: 0] += 1 }
            let top = catCounts.max(by: { $0.value < $1.value })?.key ?? .other

            let totalEngagement = slice.reduce(0) { $0 + $1.engagementSmoothed }

            blocks.append(ActivityBlock(
                id: first.i,
                activity: activityName(first),
                representativeSummary: representative,
                start: first.t,
                // Last frame + one interval, so a one-frame block still
                // has a visible duration.
                end: last.t.addingTimeInterval(captureInterval),
                frameCount: slice.count,
                redactedCount: slice.filter { $0.redacted }.count,
                meanEngagement: totalEngagement / slice.count,
                topCategory: top,
                activeSeconds: activeSeconds(slice, captureInterval: captureInterval)
            ))
            startIdx = i
        }
        return blocks
    }

    /// Seconds per category across `frames`, using the same per-frame
    /// accounting as `activeSeconds`.
    static func secondsByCategory(_ frames: [FrameEntry], captureInterval: TimeInterval) -> [FrameCategory: TimeInterval] {
        var result: [FrameCategory: TimeInterval] = [:]
        let threshold = gapThreshold(for: captureInterval)
        for i in frames.indices {
            var share = captureInterval
            if i + 1 < frames.count {
                let gap = frames[i + 1].t.timeIntervalSince(frames[i].t)
                if gap > 0 && gap <= threshold { share = min(gap, captureInterval * 2) }
            }
            result[frames[i].category, default: 0] += share
        }
        return result
    }
}
