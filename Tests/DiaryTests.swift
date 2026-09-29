import Foundation

enum DiaryTests {

    /// A realistic day: morning coding, a meeting, private admin, brief
    /// switches, and an evening session that runs past midnight.
    static func seedDay() {
        resetDataDir()
        var fs: [FrameEntry] = []
        var idx: Int64 = 0
        func add(_ start: Date, _ count: Int, _ category: FrameCategory, _ activity: String?, _ summary: String, redacted: Bool = false) {
            fs += frames(from: start, count: count, firstIndex: idx, category: category, activity: activity, summary: summary, redacted: redacted)
            idx += Int64(count)
        }
        add(date(2026, 9, 29, 9, 0), 540, .coding, "WorkTimeLaps", "editing the capture loop")      // 1h 30m
        add(date(2026, 9, 29, 10, 30), 3, .chat, "Slack", "replying in team channel")              // 30 s
        add(date(2026, 9, 29, 10, 30, 30), 3, .email, "Email triage", "archiving newsletters")     // 30 s
        add(date(2026, 9, 29, 10, 31), 270, .meeting, "Design review", "discussing onboarding flow") // 45 m
        add(date(2026, 9, 29, 11, 16), 60, .other, "Other", "Other", redacted: true)                // 10 m private
        writeSession(id: "TimeLapse_2026-09-29_09-00-00", frames: fs, note: "Shipped the diary feature")

        // After a long break, a session that crosses midnight.
        let evening = frames(from: date(2026, 9, 29, 23, 30), count: 360, firstIndex: 0,
                             category: .coding, activity: "Diary prompt", summary: "tuning the diary prompt")
        writeSession(id: "TimeLapse_2026-09-29_23-30-00", frames: evening)

        RecognitionStore.append(HighlightsTests.recognition(
            "The onboarding review was the clearest one we've had", at: date(2026, 9, 29, 11, 20)))
    }

    static func run() {
        suite("Diary material")

        test("a day's material combines every session in the work day") {
            seedDay()
            guard let m = DiaryComposer.material(for: "2026-09-29") else { return fail("no material") }
            expectEqual(m.sessions.count, 2)
            expectEqual(m.frames.count, 540 + 3 + 3 + 270 + 60 + 360)
            expectEqual(m.stats.activeSeconds, Double(m.frames.count) * 10)
            expectEqual(m.stats.firstActivity, date(2026, 9, 29, 9))
            expectEqual(m.stats.lastActivity, date(2026, 9, 30, 0, 30))
            expectEqual(m.stats.topActivities.first?.name, "WorkTimeLaps")
            expectEqual(m.stats.longestStretchActivity, "WorkTimeLaps")
            expectEqual(m.stats.redactedFrames, 60)
            expect(!m.stats.topActivities.contains { $0.name == "Other" }, "private block listed as an activity")
            expectEqual(m.recognitions.count, 1)
            expectEqual(m.notes.map(\.text), ["Shipped the diary feature"])
            expect(DiaryComposer.material(for: "2026-09-28") == nil)
        }

        test("a day mixing 10-second and one-minute sessions counts time correctly") {
            resetDataDir()
            // 30 minutes at 10 s, then an hour at one a minute.
            writeSession(id: "TimeLapse_fast", frames: frames(from: date(2026, 9, 29, 9), count: 180, interval: 10))
            var slow = RecordingSession(
                id: "TimeLapse_slow", video: "TimeLapse_slow.mp4", startedAt: date(2026, 9, 29, 10), endedAt: nil,
                lastUpdated: date(2026, 9, 29, 11), captureIntervalSec: 60, playbackFPS: 10,
                display: .init(width: 10, height: 10),
                frames: frames(from: date(2026, 9, 29, 10), count: 60, interval: 60, firstIndex: 0), summary: nil)
            slow.endedAt = date(2026, 9, 29, 11)
            slow.summary = SessionSummary.make(frames: slow.frames, captureInterval: 60)
            try SessionWriter.write(slow, to: dataDir.appendingPathComponent("TimeLapse_slow.json"))
            Journal.append(session: slow)

            guard let m = DiaryComposer.material(for: "2026-09-29") else { return fail("no material") }
            // 1h 30m, give or take one interval where the two sessions meet.
            expect(abs(m.stats.activeSeconds - 5400) <= 60, "active \(m.stats.activeSeconds)")
            expectEqual(slow.summary?.activeSeconds, 3600)
        }

        test("the prompt carries stats, a condensed timeline, praise and notes") {
            seedDay()
            let prompt = DiaryComposer.promptText(for: DiaryComposer.material(for: "2026-09-29")!)
            for needle in ["<stats>", "Worked: 3h 26m", "<timeline>",
                           "09:00–10:30 · 1h 30m · coding · WorkTimeLaps — editing the capture loop",
                           "brief switches: Slack, Email triage",
                           "[private — redacted, details withheld]",
                           "23:30–00:30 · 1h · coding · Diary prompt",
                           "<recognition>", "clearest one we've had",
                           "<notes>", "Shipped the diary feature"] {
                expect(prompt.contains(needle), "prompt is missing: \(needle)\n\(prompt)")
            }
            // Redacted content never reaches the prompt as anything but "private".
            expect(!prompt.contains("Other — Other"), "private block leaked its label")
        }

        test("long days are condensed to fit") {
            let start = date(2026, 9, 29, 9)
            var fs: [FrameEntry] = []
            for n in 0..<600 {   // 600 alternating 20 s blocks
                fs += frames(from: start.addingTimeInterval(Double(n) * 20), count: 2, firstIndex: Int64(n * 2),
                             activity: n % 2 == 0 ? "Slack" : "Mail")
            }
            let lines = DiaryComposer.timelineLines(ActivityTimeline.blocks(from: fs, captureInterval: 10), maxLines: 40)
            expect(lines.count <= 40, "\(lines.count) lines")
            expect(lines.allSatisfy { $0.contains("brief switches") })
        }

        test("a local diary is written without Claude") {
            seedDay()
            let diary = DiaryComposer.localDiary(from: DiaryComposer.material(for: "2026-09-29")!, note: "no key")
            expectEqual(diary.model, nil)
            expectEqual(diary.headline, "WorkTimeLaps and Diary prompt")
            expect(diary.entry.first?.hasPrefix("I worked 3h 26m") == true, diary.entry.first ?? "")
            expect(diary.highlights.contains("Shipped the diary feature"))
            expectEqual(diary.recognition.count, 1)
            expect(!diary.timeline.contains { $0.title == "Other" }, "private block in the local timeline")
        }

        suite("Diary storage")

        test("entries round-trip with a Markdown copy") {
            seedDay()
            let diary = DiaryComposer.localDiary(from: DiaryComposer.material(for: "2026-09-29")!, note: nil)
            try DiaryStore.save(diary)
            expect(DiaryStore.exists(dayKey: "2026-09-29"))
            expectEqual(DiaryStore.load(dayKey: "2026-09-29")?.headline, diary.headline)
            let md = try String(contentsOf: DiaryStore.markdownURL(dayKey: "2026-09-29"), encoding: .utf8)
            expect(md.hasPrefix("# "), md)
            expect(md.contains("## Where the time went"))
            expect(md.contains("> The onboarding review was the clearest one we've had — Anna"))
        }

        test("status bookkeeping persists per day") {
            resetDataDir()
            DiaryStore.updateStatus(for: "2026-09-29") { $0.attempts += 1; $0.lastError = "HTTP 529" }
            DiaryStore.updateStatus(for: "2026-09-29") { $0.attempts += 1 }
            expectEqual(DiaryStore.status(for: "2026-09-29").attempts, 2)
            expectEqual(DiaryStore.status(for: "2026-09-29").lastError, "HTTP 529")
            expectEqual(DiaryStore.status(for: "2026-09-28").attempts, 0)
        }

        test("model ids render as names") {
            expectEqual(DiaryFormat.modelName("claude-opus-5-5"), "Claude Opus 5.5")
            expectEqual(DiaryFormat.modelName("claude-opus-5"), "Claude Opus 5")
            expectEqual(DiaryFormat.modelName("claude-haiku-4-5-20251001"), "Claude Haiku 4.5")
        }

        suite("Diary request")

        test("the request asks for structured output with fallbacks") {
            let body = DiaryWriter.requestBody(model: "claude-opus-5-5", prompt: "hi")
            expect(JSONSerialization.isValidJSONObject(body), "body isn't serializable")
            expectEqual(body["model"] as? String, "claude-opus-5-5")
            expectEqual(body["stream"] as? Bool, true)
            expectEqual(body["fallbacks"] as? String, "default")
            let config = body["output_config"] as? [String: Any]
            expectEqual(config?["effort"] as? String, "medium")
            let format = config?["format"] as? [String: Any]
            expectEqual(format?["type"] as? String, "json_schema")
            let schema = format?["schema"] as? [String: Any]
            expectEqual(schema?["additionalProperties"] as? Bool, false)
            expectEqual((schema?["required"] as? [String])?.count, 6)
        }

        test("a model response decodes into a draft") {
            let json = """
            {"headline":"Shipped the diary","entry":["I spent the morning on the capture loop."],
             "highlights":["Diary feature shipped"],
             "timeline":[{"start":"09:00","end":"10:30","title":"Capture loop","detail":"Tightened timing.","category":"coding"}],
             "looseEnds":[],"dayShape":"deep_focus"}
            """
            let draft = try JSONDecoder().decode(DiaryWriter.Draft.self, from: Data(json.utf8))
            expectEqual(draft.dayShape, .deepFocus)
            expectEqual(draft.timeline.first?.category, .coding)
        }

        suite("Streaming")

        test("text blocks are assembled and thinking is ignored") {
            var p = SSEParser()
            for line in [
                "event: message_start",
                #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}"#,
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
                #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"a\":"}}"#,
                #"data: {"type":"ping"}"#,
                #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1}"}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
                #"data: {"type":"message_stop"}"#
            ] {
                try p.consume(line: line)
            }
            expectEqual(p.text, #"{"a":1}"#)
            expectEqual(p.servedModel, "claude-opus-5-5")
            expectEqual(p.stopReason, "end_turn")
            expect(p.isFinished)
        }

        test("a mid-stream fallback continues the text on the new model") {
            var p = SSEParser()
            for line in [
                #"data: {"type":"message_start","message":{"model":"claude-opus-5-5"}}"#,
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"head"}}"#,
                #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}}"#,
                #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
                #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"line\":\"x\"}"}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
            ] {
                try p.consume(line: line)
            }
            expectEqual(p.text, #"{"headline":"x"}"#)
            expectEqual(p.servedModel, "claude-opus-5")
        }

        test("refusals and stream errors surface") {
            var p = SSEParser()
            try p.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
            expectEqual(p.stopReason, "refusal")

            var q = SSEParser()
            do {
                try q.consume(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
                fail("expected an error")
            } catch let DiaryWriter.WriterError.http(status, _) {
                expectEqual(status, 529)
            }
        }

        test("API error bodies are summarized") {
            let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: unknown value"}}"#
            expectEqual(DiaryWriter.errorMessage(fromBody: body), "fallbacks: unknown value")
        }
    }
}
