import Foundation

enum HighlightsTests {

    static func recognition(_ quote: String, at t: Date, level: RecognitionLevel = .specific,
                            speaker: String? = "Anna", frameIndex: Int64 = 0) -> Recognition {
        Recognition(id: UUID().uuidString, capturedAt: t, level: level, quote: quote, speaker: speaker,
                    sourceAppBundleID: "com.tinyspeck.slackmacgap", sourceAppName: "Slack",
                    activity: "Q3 report", category: .chat, sessionID: "TimeLapse_x", frameIndex: frameIndex)
    }

    static func run() {
        suite("Highlights")

        test("the same compliment trimmed differently is recognized") {
            expect(RecognitionStore.isSameQuote(
                "Great work on the analysis — it saved us a week!",
                "great work on the analysis, it saved us a week"))
            expect(RecognitionStore.isSameQuote(
                "Hi Sam! The analysis you ran saved us a week of work",
                "The analysis you ran saved us a week of work"))
            // A long greeting kept once and trimmed once: only containment
            // catches this, word overlap is too low.
            expect(RecognitionStore.isSameQuote(
                "Hey Sam, quick note before the weekend: the analysis you ran saved us a week",
                "the analysis you ran saved us a week"))
            expect(!RecognitionStore.isSameQuote(
                "Thanks for handling the migration so carefully",
                "Thanks for the launch deck, it looked great"))
            expect(!RecognitionStore.isSameQuote("", ""))
        }

        test("a quote seen on consecutive frames is stored once, at its strongest level") {
            resetDataDir()
            let t = date(2026, 9, 29, 14, 32)
            RecognitionStore.append(recognition("The analysis you ran saved us a week", at: t, level: .specific, frameIndex: 10))
            RecognitionStore.append(recognition("The analysis you ran saved us a week!", at: t.addingTimeInterval(10), level: .specific, frameIndex: 11))
            RecognitionStore.append(recognition("the analysis you ran saved us a week", at: t.addingTimeInterval(20), level: .major, frameIndex: 12))
            let all = RecognitionStore.loadAll()
            expectEqual(all.count, 1)
            expectEqual(all.first?.level, .major)
            expectEqual(all.first?.capturedAt, t)
        }

        test("different compliments are all kept") {
            resetDataDir()
            let t = date(2026, 9, 29, 10)
            RecognitionStore.append(recognition("The analysis you ran saved us a week", at: t))
            RecognitionStore.append(recognition("Your launch deck was exactly what the board needed", at: t.addingTimeInterval(60)))
            expectEqual(RecognitionStore.loadAll().count, 2)
        }

        test("duplicates already on disk are collapsed when read") {
            resetDataDir()
            let t = date(2026, 4, 28, 11)
            let entries = [
                recognition("Thanks for jumping on the outage so quickly, you saved the demo", at: t, frameIndex: 1),
                recognition("Thanks for jumping on the outage so quickly, you saved the demo", at: t.addingTimeInterval(10), frameIndex: 2)
            ]
            try JSONFile.write(entries, to: RecognitionStore.fileURL)
            expectEqual(RecognitionStore.loadAll().count, 1)
        }

        test("an unreadable history is kept, not replaced") {
            resetDataDir()
            try "[{\"broken\": ".write(to: RecognitionStore.fileURL, atomically: true, encoding: .utf8)
            RecognitionStore.append(recognition("The analysis you ran saved us a week", at: Date()))
            expectEqual(RecognitionStore.loadAll().count, 1)
            let names = try FileManager.default.contentsOfDirectory(atPath: Journal.folder.path)
            expect(names.contains { $0.hasPrefix("recognitions.unreadable-") }, "broken history wasn't kept")
        }

        test("one bad entry doesn't hide the rest") {
            resetDataDir()
            let good = recognition("The analysis you ran saved us a week", at: date(2026, 9, 29, 9))
            let goodJSON = String(data: try JSONFile.prettyEncoder.encode(good), encoding: .utf8)!
            try "[\(goodJSON), {\"id\": 42}]".write(to: RecognitionStore.fileURL, atomically: true, encoding: .utf8)
            expectEqual(RecognitionStore.loadAll().count, 1)
        }

        test("recognitions are grouped by work day") {
            resetDataDir()
            RecognitionStore.append(recognition("Late-night praise for the fix, thank you so much", at: date(2026, 9, 30, 1, 15)))
            expectEqual(RecognitionStore.load(workDay: "2026-09-29").count, 1)
            expectEqual(RecognitionStore.load(workDay: "2026-09-30").count, 0)
        }
    }
}
