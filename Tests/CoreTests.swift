import Foundation
import CoreGraphics

enum CoreTests {

    static func run() {
        suite("Work days")

        test("times before the cutoff belong to the previous day") {
            expectEqual(WorkDay.key(for: date(2026, 9, 30, 1, 30), cutoffHour: 2), "2026-09-29")
            expectEqual(WorkDay.key(for: date(2026, 9, 30, 1, 59, 59), cutoffHour: 2), "2026-09-29")
            expectEqual(WorkDay.key(for: date(2026, 9, 30, 2, 0), cutoffHour: 2), "2026-09-30")
            expectEqual(WorkDay.key(for: date(2026, 9, 30, 23, 59), cutoffHour: 2), "2026-09-30")
        }

        test("a midnight cutoff means calendar days") {
            expectEqual(WorkDay.key(for: date(2026, 9, 30, 0, 30), cutoffHour: 0), "2026-09-30")
            expectEqual(WorkDay.key(for: date(2026, 9, 29, 23, 59), cutoffHour: 0), "2026-09-29")
        }

        test("interval runs from cutoff to cutoff") {
            let interval = WorkDay.interval(forKey: "2026-09-29", cutoffHour: 2)!
            expectEqual(interval.start, date(2026, 9, 29, 2))
            expectEqual(interval.end, date(2026, 9, 30, 2))
            expectEqual(WorkDay.nextBoundary(after: date(2026, 9, 29, 23), cutoffHour: 2), date(2026, 9, 30, 2))
            expectEqual(WorkDay.nextBoundary(after: date(2026, 9, 30, 1), cutoffHour: 2), date(2026, 9, 30, 2))
        }

        test("work days tile the whole year, including DST changes") {
            // Every day's interval must start where the previous one ended,
            // and every instant must map back to the day that contains it.
            var day = date(2026, 1, 1)
            var previousEnd: Date?
            for _ in 0..<366 {
                let key = WorkDay.key(forDay: day)
                let interval = WorkDay.interval(forDay: day, cutoffHour: 2)
                if let previousEnd { expectEqual(interval.start, previousEnd, "gap before \(key)") }
                expectEqual(WorkDay.key(for: interval.start, cutoffHour: 2), key, "start of \(key)")
                expectEqual(WorkDay.key(for: interval.end.addingTimeInterval(-1), cutoffHour: 2), key, "end of \(key)")
                let hours = interval.duration / 3600
                expect(hours >= 23 && hours <= 25, "\(key) is \(hours) hours long")
                previousEnd = interval.end
                day = WorkDay.calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }

        test("key arithmetic and validation") {
            expectEqual(WorkDay.key("2026-10-01", offsetBy: -1), "2026-09-30")
            expectEqual(WorkDay.key("2026-12-31", offsetBy: 1), "2027-01-01")
            expect(WorkDay.isKey("2026-09-29"))
            expect(!WorkDay.isKey("activities"))
            expect(!WorkDay.isKey("recognitions"))
        }

        suite("Activity timeline")

        test("blocks split on activity changes and on long gaps") {
            let start = date(2026, 9, 29, 9)
            var fs = frames(from: start, count: 3, activity: "Stripe")
            fs += frames(from: start.addingTimeInterval(30), count: 2, firstIndex: 3, activity: "Linear")
            // Same activity after a 10-minute absence: a new block.
            fs += frames(from: start.addingTimeInterval(640), count: 2, firstIndex: 5, activity: "Linear")
            let blocks = ActivityTimeline.blocks(from: fs, captureInterval: 10)
            expectEqual(blocks.map(\.activity), ["Stripe", "Linear", "Linear"])
            expectEqual(blocks.map(\.frameCount), [3, 2, 2])
            expectEqual(blocks[0].activeSeconds, 30)
        }

        test("active time leaves absences out") {
            let start = date(2026, 9, 29, 9)
            var fs = frames(from: start, count: 6)                                   // 60 s
            fs += frames(from: start.addingTimeInterval(3600), count: 3, firstIndex: 6) // 30 s after an hour away
            expectEqual(ActivityTimeline.activeSeconds(fs, captureInterval: 10), 90)
            let byCategory = ActivityTimeline.secondsByCategory(fs, captureInterval: 10)
            expectEqual(byCategory.values.reduce(0, +), 90)
        }

        test("a slow analyzer call doesn't look like an absence") {
            let start = date(2026, 9, 29, 9)
            let fs = [frame(0, at: start), frame(1, at: start.addingTimeInterval(38)), frame(2, at: start.addingTimeInterval(48))]
            expectEqual(ActivityTimeline.blocks(from: fs, captureInterval: 10).count, 1)
        }

        test("frames without an activity fall back to the category name") {
            let f = frame(0, at: Date(), category: .email, activity: nil)
            expectEqual(ActivityTimeline.activityName(f), "Email")
        }

        suite("Decoding")

        test("unknown enum values decode to safe defaults") {
            let json = """
            {"i":0,"t":"2026-09-29T09:00:00Z","category":"spreadsheets","summary":"x",
             "engagement":1,"engagementSmoothed":1,"redacted":false}
            """
            let entry = try JSONFile.decoder.decode(FrameEntry.self, from: Data(json.utf8))
            expectEqual(entry.category, .other)
            let level = try JSONFile.decoder.decode([RecognitionLevel].self, from: Data(#"["legendary","major"]"#.utf8))
            expectEqual(level, [.none, .major])
        }

        test("session summaries record active time") {
            let fs = frames(from: date(2026, 9, 29, 9), count: 12)
            let summary = SessionSummary.make(frames: fs, captureInterval: 10)
            expectEqual(summary.totalFrames, 12)
            expectEqual(summary.activeSeconds, 120)
            expectEqual(summary.topCategory, .coding)
        }

        suite("Storage")

        test("unreadable files are moved aside, never overwritten") {
            resetDataDir()
            let url = dataDir.appendingPathComponent("thing.json")
            try "not json".write(to: url, atomically: true, encoding: .utf8)
            guard case .unreadable = JSONFile.read([String].self, from: url) else {
                return fail("expected .unreadable")
            }
            let moved = JSONFile.quarantine(url)
            expect(moved != nil && FileManager.default.fileExists(atPath: moved!.path))
            expect(!FileManager.default.fileExists(atPath: url.path))
            guard case .missing = JSONFile.read([String].self, from: url) else {
                return fail("expected .missing after quarantine")
            }
        }

        suite("Video retention")

        test("only expired videos and thumbnails are deleted") {
            resetDataDir()
            let fm = FileManager.default
            let now = Date()
            let old = now.addingTimeInterval(-72 * 3600)
            let fresh = now.addingTimeInterval(-3600)
            let files: [(String, Date)] = [
                ("TimeLapse_old.mp4", old),
                ("TimeLapse_old.thumb.jpg", old),
                ("TimeLapse_old.json", old),
                ("TimeLapse_new.mp4", fresh),
                ("TimeLapse_live.mp4", old),
                ("holiday.mp4", old)
            ]
            for (name, modified) in files {
                let url = dataDir.appendingPathComponent(name)
                fm.createFile(atPath: url.path, contents: Data("x".utf8))
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            let deleted = RetentionSweeper.sweep(now: now, protecting: ["TimeLapse_live.mp4"])
            expectEqual(deleted, 2)
            let remaining = Set(try fm.contentsOfDirectory(atPath: dataDir.path))
            expectEqual(remaining, ["TimeLapse_old.json", "TimeLapse_new.mp4", "TimeLapse_live.mp4", "holiday.mp4"])
        }

        suite("Screens")

        // Your setup: two 1920×1080 screens either side of a 1728×1117 laptop.
        let laptop: CGDirectDisplayID = 1, left: CGDirectDisplayID = 2, right: CGDirectDisplayID = 3
        let layout: [CGDirectDisplayID: CGRect] = [
            laptop: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            left: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            right: CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        ]

        test("the screen with the active window is the one captured") {
            let chrome = CGRect(x: -1800, y: 40, width: 1500, height: 900)
            expectEqual(Screens.focusedDisplay(window: chrome, mouse: nil, displays: layout, main: laptop), left)
            // A window straddling two screens belongs to the one showing more of it.
            let straddling = CGRect(x: 1500, y: 100, width: 1200, height: 600)
            expectEqual(Screens.focusedDisplay(window: straddling, mouse: nil, displays: layout, main: laptop), right)
        }

        test("without a window, the screen under the pointer, then the main screen") {
            expectEqual(Screens.focusedDisplay(window: nil, mouse: CGPoint(x: 2500, y: 500), displays: layout, main: laptop), right)
            expectEqual(Screens.focusedDisplay(window: nil, mouse: nil, displays: layout, main: laptop), laptop)
            let offscreen = CGRect(x: 9000, y: 9000, width: 10, height: 10)
            expectEqual(Screens.focusedDisplay(window: offscreen, mouse: nil, displays: layout, main: laptop), laptop)
        }

        test("identical screens are told apart by position") {
            let names = Screens.displayNames([
                .init(id: laptop, name: "Built-in Retina Display", bounds: layout[laptop]!),
                .init(id: left, name: "S17", bounds: layout[left]!),
                .init(id: right, name: "S17", bounds: layout[right]!)
            ], main: laptop)
            expectEqual(names[laptop], "Built-in Retina Display")
            expectEqual(names[left], "S17 (left)")
            expectEqual(names[right], "S17 (right)")
        }

        test("one video frame fits every screen without stretching") {
            let canvas = Screens.canvasSize(for: [CGSize(width: 1728, height: 1117), CGSize(width: 1920, height: 1080)])
            expectEqual(canvas.width, 1920)
            expectEqual(canvas.height, 1118)
            let laptopFit = Screens.aspectFitRect(CGSize(width: 1728, height: 1117), in: CGSize(width: 1920, height: 1118))
            expectEqual(laptopFit.height, 1118)
            expect(laptopFit.minX > 0 && abs(laptopFit.midX - 960) <= 1, "laptop frame isn't centered: \(laptopFit)")
            let monitorFit = Screens.aspectFitRect(CGSize(width: 1920, height: 1080), in: CGSize(width: 1920, height: 1118))
            expectEqual(monitorFit.width, 1920)
            expectEqual(monitorFit.minY, 19)
        }

        suite("Journal and recovery")

        test("the newest frame on disk is found for the menu") {
            resetDataDir()
            expect(Journal.lastRecordedFrameTime() == nil)
            writeSession(id: "TimeLapse_older", frames: frames(from: date(2026, 9, 29, 9), count: 3))
            writeSession(id: "TimeLapse_newer", frames: frames(from: date(2026, 9, 30, 14), count: 4))
            expectEqual(Journal.lastRecordedFrameTime(), date(2026, 9, 30, 14).addingTimeInterval(30))
        }

        test("the menu's relative times read naturally") {
            let now = date(2026, 10, 1, 9, 30)
            expectEqual(MenuBarController.relative(now.addingTimeInterval(-20), now: now), "just now")
            expectEqual(MenuBarController.relative(now.addingTimeInterval(-4 * 60), now: now), "4 min ago")
            expectEqual(MenuBarController.relative(now.addingTimeInterval(-3 * 3600), now: now), "3 h ago")
        }

        test("sessions are filed under the work day they started in") {
            resetDataDir()
            writeSession(id: "TimeLapse_late", frames: frames(from: date(2026, 9, 30, 1, 0), count: 6))
            expect(Journal.load(dayKey: "2026-09-29")?.sessions.count == 1, "late session missing from the 29th")
            expect(Journal.load(dayKey: "2026-09-30") == nil)
        }

        test("an unreadable day log is kept aside when a session is added") {
            resetDataDir()
            try "{broken".write(to: Journal.url(forKey: "2026-09-29"), atomically: true, encoding: .utf8)
            writeSession(id: "TimeLapse_a", frames: frames(from: date(2026, 9, 29, 10), count: 3))
            expectEqual(Journal.load(dayKey: "2026-09-29")?.sessions.count, 1)
            let names = try FileManager.default.contentsOfDirectory(atPath: Journal.folder.path)
            expect(names.contains { $0.hasPrefix("2026-09-29.unreadable-") }, "broken file wasn't kept")
        }

        test("unfinished sessions are closed out on launch") {
            resetDataDir()
            writeSession(id: "TimeLapse_crashed", frames: frames(from: date(2026, 9, 29, 14), count: 30), finished: false)
            let emptyShell = RecordingSession(
                id: "TimeLapse_empty", video: "TimeLapse_empty.mp4", startedAt: date(2026, 9, 29, 15), endedAt: nil,
                lastUpdated: date(2026, 9, 29, 15), captureIntervalSec: 10, playbackFPS: 10,
                display: .init(width: 10, height: 10), frames: [], summary: nil)
            try SessionWriter.write(emptyShell, to: dataDir.appendingPathComponent("TimeLapse_empty.json"))

            expectEqual(SessionRecovery.recoverUnfinishedSessions(), 1)
            let recovered = try SessionWriter.read(from: dataDir.appendingPathComponent("TimeLapse_crashed.json"))
            expectEqual(recovered.endedAt, date(2026, 9, 29, 14).addingTimeInterval(300))
            expectEqual(recovered.summary?.totalFrames, 30)
            expectEqual(Journal.load(dayKey: "2026-09-29")?.sessions.first?.id, "TimeLapse_crashed")
            expect(!FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("TimeLapse_empty.json").path))
            // Running again is a no-op.
            expectEqual(SessionRecovery.recoverUnfinishedSessions(), 0)
        }
    }
}
