import Foundation

// A deliberately tiny test harness: the project builds with plain `swiftc`
// (no Xcode project, no SwiftPM), so XCTest isn't available. See
// scripts/test.sh for how the test binary is built and run.

var testFailures = 0
var testCount = 0
private var currentTest = ""
private var failuresAtStart = 0

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    testCount += 1
    failuresAtStart = testFailures
    do {
        try body()
    } catch {
        fail("threw \(error)")
    }
    print(testFailures == failuresAtStart ? "  ✓ \(name)" : "  ✗ \(name)")
}

func suite(_ name: String) {
    print("\n\(name)")
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    testFailures += 1
    print("      \(message)  [\(file):\(line)]")
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition { fail(message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        fail("expected \(expected), got \(actual)\(message.isEmpty ? "" : " — \(message)")", file: file, line: line)
    }
}

// MARK: - Fixtures

/// The isolated data folder set by scripts/test.sh via WORKTIMELAPS_DATA_DIR.
var dataDir: URL { TimeLapseRecorder.recordingsFolder }

/// Empties the data folder between tests.
func resetDataDir() {
    let fm = FileManager.default
    guard ProcessInfo.processInfo.environment["WORKTIMELAPS_DATA_DIR"] != nil else {
        fatalError("Refusing to run: WORKTIMELAPS_DATA_DIR isn't set, tests would touch real data.")
    }
    for url in (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: url)
    }
}

/// A local date from components, in the process time zone.
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    return WorkDay.calendar.date(from: c)!
}

func frame(_ i: Int64, at t: Date, category: FrameCategory = .coding, activity: String? = "WorkTimeLaps",
           summary: String = "editing Swift", engagement: Int = 70, redacted: Bool = false) -> FrameEntry {
    FrameEntry(i: i, t: t, category: category, summary: summary, engagement: engagement,
               engagementSmoothed: engagement, redacted: redacted,
               redactionReason: redacted ? "privacy:financial" : nil, sleepGapSec: nil, activity: activity)
}

/// `count` frames every `interval` seconds starting at `start`.
func frames(from start: Date, count: Int, interval: TimeInterval = 10, firstIndex: Int64 = 0,
            category: FrameCategory = .coding, activity: String? = "WorkTimeLaps",
            summary: String = "editing Swift", redacted: Bool = false) -> [FrameEntry] {
    (0..<count).map { n in
        frame(firstIndex + Int64(n), at: start.addingTimeInterval(Double(n) * interval),
              category: category, activity: activity, summary: summary, redacted: redacted)
    }
}

/// Writes a finished session (sidecar + journal entry) to the data folder.
@discardableResult
func writeSession(id: String, frames: [FrameEntry], finished: Bool = true, note: String? = nil) -> RecordingSession {
    var session = RecordingSession(
        id: id, video: "\(id).mp4", startedAt: frames.first!.t, endedAt: nil,
        lastUpdated: frames.last!.t, captureIntervalSec: 10, playbackFPS: 10,
        display: .init(width: 1920, height: 1080), frames: frames, summary: nil)
    if finished {
        session.endedAt = frames.last!.t.addingTimeInterval(10)
        session.summary = SessionSummary.make(frames: frames, captureInterval: 10)
    }
    try! SessionWriter.write(session, to: dataDir.appendingPathComponent("\(id).json"))
    if finished {
        Journal.append(session: session)
        if let note {
            Journal.setNote(sessionID: id, dayKey: WorkDay.key(for: session.startedAt), note: note)
        }
    }
    return session
}
