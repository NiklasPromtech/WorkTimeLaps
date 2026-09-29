import Foundation

enum PlanTests {

    static let peterAsk = ConversationSnapshot(
        with: "Peter Källström", app: "LinkedIn", topic: "Erik and the Gant analysis",
        lastFrom: "me", request: "Peter to get back about Erik", requestBy: "me")

    static func stats() -> DayStats {
        DayStats(activeSeconds: 3600, firstActivity: nil, lastActivity: nil, sessions: 1, frames: 60,
                 redactedFrames: 0, categorySeconds: [:], topActivities: [], longestStretchSeconds: 0,
                 longestStretchActivity: nil, switches: 0)
    }

    static func update(_ id: String, _ with: String, _ request: String, owner: String = "them",
                       status: String = "open", note: String = "") -> FollowUpUpdate {
        FollowUpUpdate(id: id, with: with, request: request, owner: owner, since: "2026-09-29", status: status, note: note)
    }

    static func run() {
        suite("Planning signals from screenshots")

        test("conversations and meetings are read from the analyzer's answer") {
            let json = """
            {"safe": true, "category": "chat", "activity": "LinkedIn", "summary": "messaging Peter",
             "engagement": 50, "privacy": "none", "sameAsBefore": false, "recognitionLevel": "none",
             "recognitionQuote": "", "recognitionSpeaker": "",
             "conversation": {"with": "Peter Källström", "app": "LinkedIn", "topic": "Erik and the Gant analysis",
                              "lastFrom": "me", "request": "Peter to get back about Erik", "requestBy": "me"},
             "meetings": [{"title": "Sync with Peter", "start": "2026-09-30T14:00", "with": "Peter Källström"},
                          {"title": "", "start": "2026-09-30T15:00", "with": ""}]}
            """
            guard case .analyzed(let a) = FrameAnalyzer(apiKey: "test").parseAnalysisJSON(json) else {
                return fail("not analyzed")
            }
            expectEqual(a.conversation?.with, "Peter Källström")
            expectEqual(a.conversation?.requestBy, "me")
            expect(a.conversation?.hasOpenRequest == true)
            expectEqual(a.meetings.map(\.title), ["Sync with Peter"])
            expectEqual(a.meetings.first?.startDate, date(2026, 9, 30, 14))
        }

        test("frames tagged private keep no conversation or meeting details") {
            let json = """
            {"safe": true, "category": "chat", "activity": "Messages", "summary": "Chat", "engagement": 30,
             "privacy": "personal_messages", "sameAsBefore": false, "recognitionLevel": "none",
             "recognitionQuote": "", "recognitionSpeaker": "",
             "conversation": {"with": "Mum", "app": "WhatsApp", "topic": "Dinner", "lastFrom": "them",
                              "request": "Call Mum back", "requestBy": "them"},
             "meetings": [{"title": "Dentist", "start": "2026-09-30T08:00", "with": ""}]}
            """
            guard case .analyzed(let a) = FrameAnalyzer(apiKey: "test").parseAnalysisJSON(json) else {
                return fail("not analyzed")
            }
            expect(a.conversation == nil)
            expect(a.meetings.isEmpty)
        }

        test("the analyzer only asks for planning signals when they're turned on") {
            let on = FrameAnalyzer.buildPrompt(previous: nil, vocabulary: [], userName: "Sam Doe",
                                               now: date(2026, 9, 29, 9), extractPlanning: true)
            expect(on.contains("Current local time: Tuesday 2026-09-29 09:00."), "missing the clock")
            expect(on.contains("\"conversation\": fill ONLY"))
            expect(on.contains("\"meetings\": upcoming meetings"))
            expect(on.contains("\"Sam, …\""), "first name not used in the recognition examples")
            let off = FrameAnalyzer.buildPrompt(previous: nil, vocabulary: [], userName: "Sam Doe",
                                                now: date(2026, 9, 29, 9), extractPlanning: false)
            expect(!off.contains("\"conversation\""))
            expect(!off.contains("\"meetings\""))
        }

        suite("Follow-ups")

        test("the brief's list is merged without duplicates") {
            resetDataDir()
            let now = date(2026, 9, 29, 9)
            FollowUpStore.apply([update("new", "Peter Källström", "Peter to get back about Erik")], now: now)
            // The next brief lists it as new again, worded a little differently.
            FollowUpStore.apply([update("new", "Peter Källström", "Peter to get back to me about Erik", note: "Nudge Peter")], now: now)
            let all = FollowUpStore.loadAll()
            expectEqual(all.count, 1)
            expectEqual(all.first?.note, "Nudge Peter")
            expect(all.first?.isWaitingOnThem == true)
        }

        test("something marked done is never reopened by the brief") {
            resetDataDir()
            FollowUpStore.apply([update("new", "Peter Källström", "Peter to get back about Erik")])
            let peter = FollowUpStore.open[0]
            FollowUpStore.setDone(id: peter.id, true)
            FollowUpStore.apply([update(peter.id, "Peter Källström", "Peter to get back about Erik")])
            FollowUpStore.apply([update("new", "Peter Källström", "Peter to get back about Erik")])
            expect(FollowUpStore.open.isEmpty, "reopened: \(FollowUpStore.open.map(\.request))")
            expectEqual(FollowUpStore.recentlyClosedByUser().map(\.with), ["Peter Källström"])
            // Undo from the Diary window works.
            FollowUpStore.setDone(id: peter.id, false)
            expectEqual(FollowUpStore.open.count, 1)
        }

        test("items the brief doesn't mention are kept, and replies resolve them") {
            resetDataDir()
            FollowUpStore.apply([update("new", "Anna", "Send Anna the pricing sheet", owner: "me")])
            FollowUpStore.apply([])
            let anna = FollowUpStore.open
            expectEqual(anna.map(\.with), ["Anna"])
            expect(anna.first?.isWaitingOnThem == false)
            FollowUpStore.apply([update(anna[0].id, "Anna", "Send Anna the pricing sheet", owner: "me", status: "resolved")])
            expect(FollowUpStore.open.isEmpty)
        }

        suite("Plan context")

        test("the plan gathers conversations, follow-ups, meetings and recent work") {
            resetDataDir()
            var fs = frames(from: date(2026, 9, 29, 10, 30), count: 3, category: .chat,
                            activity: "LinkedIn", summary: "messaging Peter")
            fs[0].conversation = peterAsk
            fs[1].conversation = peterAsk
            fs[2].meetings = [
                MeetingMention(title: "Sync with Peter", start: "2026-09-30T14:00", with: "Peter Källström"),
                MeetingMention(title: "Last week's review", start: "2026-09-22T10:00", with: nil)
            ]
            writeSession(id: "TimeLapse_plan", frames: fs)
            try DiaryStore.save(WorkDiary(
                dayKey: "2026-09-24", generatedAt: date(2026, 9, 25, 2), model: nil,
                headline: "Drafted the Gant analysis", entry: ["…"], highlights: ["Pricing model v1"],
                timeline: [], looseEnds: [], dayShape: nil, stats: stats(), recognition: [], note: nil))
            FollowUpStore.apply([update("new", "Anna", "Send Anna the pricing sheet", owner: "me")])

            guard let material = DiaryComposer.material(for: "2026-09-29") else { return fail("no material") }
            let ctx = DiaryComposer.planContext(for: material, planDayKey: "2026-09-30",
                                                includeFollowUps: true, now: date(2026, 9, 30, 2, 5))
            expectEqual(ctx.meetings.map(\.title), ["Sync with Peter"])
            expect(ctx.conversations.first?.contains("you asked: Peter to get back about Erik") == true,
                   ctx.conversations.first ?? "no conversation line")
            expect(ctx.recentWork.contains { $0.contains("Drafted the Gant analysis") })

            let text = DiaryComposer.planPromptText(ctx)
            for needle in ["<plan_day>", "<conversations>", "Peter Källström (LinkedIn)",
                           "<open_followups>", "you owe Anna: Send Anna the pricing sheet",
                           "<upcoming_meetings>", "2026-09-30 14:00 · Sync with Peter · with Peter Källström",
                           "<recent_work>", "2026-09-24 — Drafted the Gant analysis"] {
                expect(text.contains(needle), "plan prompt is missing: \(needle)\n\(text)")
            }

            let off = DiaryComposer.planContext(for: material, planDayKey: "2026-09-30",
                                                includeFollowUps: false, now: date(2026, 9, 30, 2, 5))
            expect(off.conversations.isEmpty && off.meetings.isEmpty && off.openFollowUps.isEmpty)
        }

        suite("Brief request and storage")

        test("the request asks for the plan only when there is one") {
            let with = DiaryWriter.requestBody(model: "claude-opus-5-5", prompt: "hi", includePlan: true)
            expect(JSONSerialization.isValidJSONObject(with))
            let format = (with["output_config"] as? [String: Any])?["format"] as? [String: Any]
            let required = (format?["schema"] as? [String: Any])?["required"] as? [String] ?? []
            expect(required.contains("today") && required.contains("followUps"), "\(required)")
            expect((with["system"] as? String)?.contains("today.meetings") == true)

            let without = DiaryWriter.requestBody(model: "claude-opus-5-5", prompt: "hi", includePlan: false)
            let plainFormat = (without["output_config"] as? [String: Any])?["format"] as? [String: Any]
            let plainRequired = (plainFormat?["schema"] as? [String: Any])?["required"] as? [String] ?? []
            expect(!plainRequired.contains("today"))
        }

        test("a brief with a plan decodes") {
            let json = """
            {"headline": "Prepped the Gant pitch", "entry": ["…"], "highlights": [], "timeline": [],
             "looseEnds": [], "dayShape": "steady",
             "today": {"focus": ["Finish the pricing slide"],
                       "meetings": [{"title": "Sync with Peter", "time": "14:00", "with": "Peter Källström",
                                     "context": "You worked on the Gant analysis last week.", "prepared": false,
                                     "questions": ["What did Erik say about budget?"]}]},
             "followUps": [{"id": "new", "with": "Peter Källström", "request": "Peter to get back about Erik",
                            "owner": "them", "since": "2026-09-29", "status": "open", "note": "Nudge Peter"}]}
            """
            let draft = try JSONDecoder().decode(DiaryWriter.Draft.self, from: Data(json.utf8))
            expectEqual(draft.today?.meetings.first?.prepared, false)
            expectEqual(draft.followUps?.first?.owner, "them")
        }

        test("the Markdown copy includes the plan") {
            let plan = DayPlan(
                dayKey: "2026-09-30",
                focus: ["Finish the pricing slide"],
                meetings: [DayPlan.MeetingPrep(title: "Sync with Peter", time: "14:00", with: "Peter Källström",
                                               context: "You worked on the Gant analysis last week.",
                                               prepared: false, questions: ["What did Erik say about budget?"])],
                waitingOn: [DayPlan.FollowUpItem(FollowUp(
                    id: "1", with: "Peter Källström", request: "Peter to get back about Erik", owner: "them",
                    since: "2026-09-29", status: "open", note: "Nudge Peter", closedByUser: nil, updatedAt: Date()))],
                youOwe: [])
            var diary = WorkDiary(
                dayKey: "2026-09-29", generatedAt: Date(), model: "claude-opus-5-5", headline: "Prepped the Gant pitch",
                entry: ["…"], highlights: [], timeline: [], looseEnds: [], dayShape: .steady, stats: stats(),
                recognition: [], note: nil)
            diary.today = plan
            let md = DiaryStore.markdown(for: diary)
            for needle in ["## Today — ", "- Finish the pricing slide", "**14:00 Sync with Peter** with Peter Källström — not prepped yet",
                           "- What did Erik say about budget?", "**Waiting on**", "- Peter Källström: Peter to get back about Erik (since 2026-09-29)"] {
                expect(md.contains(needle), "markdown is missing: \(needle)\n\(md)")
            }
        }
    }
}
