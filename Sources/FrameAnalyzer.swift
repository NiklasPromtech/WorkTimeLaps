import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Sends each screenshot to Claude Haiku and gets back a combined verdict:
/// is it safe to share, what's the user doing (category + short summary),
/// and how engaged does the moment look (0-100). All four signals in a
/// single API call so per-frame cost stays in the fractions-of-a-cent range.
///
/// Not @MainActor — safe to call from any task. Network I/O happens on
/// URLSession's default (background) queue.
///
/// Fail-closed by contract: if the network fails, the JSON is malformed, or
/// any required field is missing, we return `.failed(reason)` and
/// TimeLapseRecorder treats the frame as unsafe (redacts it): a flaky network
/// must never silently disable the protection.
struct FrameAnalyzer: Sendable {

    enum Outcome: Sendable {
        case analyzed(FrameAnalysis)
        case failed(String)
    }

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = "claude-haiku-4-5-20251001") {
        self.apiKey = apiKey
        self.model = model
    }

    /// What the previous frame returned, so the model can reuse the same
    /// activity name verbatim and answer "is this still the same?" Set to
    /// nil for the first frame of a session.
    struct PreviousFrameContext: Sendable {
        let activity: String
        let summary: String
        let category: FrameCategory
    }

    func analyze(image: CGImage,
                 previous: PreviousFrameContext? = nil,
                 vocabulary: [ActivityEntry] = [],
                 userName: String? = nil,
                 now: Date = Date(),
                 extractPlanning: Bool = true) async -> Outcome {
        guard let base64 = Self.encodeAsJPEG(image: image, maxDimension: 1568, quality: 0.7) else {
            return .failed("couldn't encode screenshot as JPEG")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        // One prompt producing one JSON object. We list the exact category
        // and privacy vocabularies here (same lists as the FrameCategory /
        // PrivacyTag enums) so the model can't invent new buckets — `other`
        // and `none` are the escape hatches. The `activity` field, in
        // contrast, is open vocabulary anchored by the rolling 2-hour list
        // we send below.
        let prompt = Self.buildPrompt(previous: previous,
                                      vocabulary: vocabulary,
                                      userName: userName,
                                      now: now,
                                      extractPlanning: extractPlanning)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failed("json encode: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failed("network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? "<non-utf8>"
            return .failed("HTTP \(http.statusCode): \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = first["text"] as? String else {
            return .failed("unexpected API response shape")
        }

        return parseAnalysisJSON(text)
    }

    // MARK: - Prompt construction

    static func buildPrompt(previous: PreviousFrameContext?,
                            vocabulary: [ActivityEntry],
                            userName: String?,
                            now: Date = Date(),
                            extractPlanning: Bool = true) -> String {
        // Recent vocabulary block. Empty on a totally fresh install or
        // after a long pause; that's fine — model creates a fresh entry.
        let vocabBlock: String = {
            guard !vocabulary.isEmpty else {
                return "Recent activities: (none — pick a specific name yourself)"
            }
            let lines = vocabulary.map { entry -> String in
                let examples = entry.examples.prefix(2).joined(separator: " · ")
                if examples.isEmpty {
                    return "  - \"\(entry.name)\""
                }
                return "  - \"\(entry.name)\"  e.g. \(examples)"
            }
            return "Recent activities (REUSE the exact name when it matches):\n" + lines.joined(separator: "\n")
        }()

        let previousBlock: String = {
            guard let p = previous else {
                return "Previous frame: none (this is the first frame of the session)"
            }
            return """
            Previous frame:
              activity: "\(p.activity)"
              summary:  "\(p.summary)"
              category: \(p.category.rawValue)
            """
        }()

        let userBlock: String = {
            guard let name = userName, !name.isEmpty else {
                return "User identity: unknown."
            }
            return "User identity: the person using this Mac is \"\(name)\". When evaluating recognition, this is the only person whose praise should ever count — never log praise addressed to anyone else."
        }()

        // First name for the "addressed by name" examples below.
        let firstName = userName?
            .split(separator: " ")
            .first
            .map(String.init) ?? "the user"

        let clock: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
            return f.string(from: now)
        }()

        // Conversations and meetings feed the morning brief's plan for the
        // day. Left out entirely when the user turns that off.
        let planningShape = extractPlanning ? """
        ,
          "conversation": <null, or {"with": "...", "app": "...", "topic": "...", "lastFrom": "me|them", "request": "...", "requestBy": "me|them|none"}>,
          "meetings": [<{"title": "...", "start": "YYYY-MM-DDTHH:MM", "with": "..."}>, ...]
        """ : ""

        let planningRules = extractPlanning ? """

        "conversation": fill ONLY when the frame shows a readable work \
        conversation the user takes part in: a chat thread, direct message, \
        email thread or comment thread (Slack, Teams, LinkedIn, email, GitHub \
        and similar). Otherwise null. ALWAYS null when "privacy" is not "none".
          - "with": the other person's name as shown, or the channel or group name.
          - "app": where the conversation is, e.g. "Slack", "LinkedIn", "Gmail".
          - "topic": what it is about, under 8 words, in English.
          - "lastFrom": "me" if the most recent visible message was written by \
        the user, "them" if by someone else.
          - "request": if the latest messages leave an ask unanswered (someone \
        asked the other side to reply, decide, send or do something), describe \
        it as a short action in English with names, e.g. "Peter to get back \
        about Erik" or "Send Anna the pricing sheet". Empty string if nothing \
        is waiting.
          - "requestBy": "me" if the user made the ask (the user is waiting on \
        them), "them" if the other side asked the user, "none" if "request" \
        is empty.
          Messages may be in any language; write "topic" and "request" in English.

        "meetings": upcoming meetings clearly visible on screen: in a \
        calendar, a meeting invite, or a message confirming a time. Use the \
        current local time above to resolve words like "tomorrow" or a \
        weekday. Up to 6, soonest first. Skip meetings that have already ended \
        and all-day events. Empty array when none are visible, and always \
        empty when "privacy" is not "none".
          - "title": the meeting's title.
          - "start": local start time as YYYY-MM-DDTHH:MM.
          - "with": attendee or organizer names if shown, otherwise empty string.
        """ : ""

        return """
        You are analyzing a screen-recording frame for a local macOS tool. \
        Output JSON and nothing else — no prose, no markdown fences.

        Current local time: \(clock).

        \(userBlock)

        \(vocabBlock)

        \(previousBlock)

        Respond with this exact shape:
        {
          "safe": <boolean>,
          "category": "<one of: coding|writing|email|chat|meeting|browsing|design|terminal|reading|media|other>",
          "activity": "<specific tool or task name; see rules>",
          "summary": "<under 10 words describing what the user is doing>",
          "engagement": <integer 0-100>,
          "privacy": "<one of: none|financial|personal_messages|medical|hr_legal>",
          "sameAsBefore": <boolean>,
          "recognitionLevel": "<one of: none|weak|specific|major>",
          "recognitionQuote": "<the quoted praise text, or empty string>",
          "recognitionSpeaker": "<who said it, or empty string>"\(planningShape)
        }

        Field rules:

        "safe": false ONLY if the frame shows any of:
          - API keys, bearer/session tokens, or JWTs in plaintext
          - Private keys (PEM, SSH, etc.)
          - Passwords shown as real characters (NOT dots/bullets in a password field)
          - Database connection strings or URLs with embedded credentials
          - Secret values visible in .env files or terminal output
          - Credit-card numbers, SSNs, or similar sensitive personal identifiers
        Otherwise "safe": true.

        "category": closed list. Best match from above.
          - coding: editing source code
          - writing: prose, docs, notes, long-form text
          - email: Mail / Gmail / Outlook
          - chat: Slack / Discord / iMessage / Teams chat
          - meeting: Zoom / Meet / FaceTime / Teams call
          - browsing: general web not covered above
          - design: Figma / Sketch / Photoshop / Illustrator / Lovable
          - terminal: shell window, tmux, SSH session
          - reading: docs, PDFs, articles
          - media: video players, music, games, YouTube
          - other: anything else

        "activity": OPEN vocabulary, anchored to the recent list above.
          - If the frame matches one of the recent activities exactly, REUSE \
        that name character-for-character. Don't paraphrase. The point of \
        the list is consistency.
          - If nothing matches, invent a NEW name. Critical rules for new names:
            * Be SPECIFIC. Prefer a tool/product name (e.g. "Stripe", "Lovable", \
        "Google Ads", "Squarespace", "Linear", "Notion", "Figma", "GitHub PR") \
        or a specific verb-phrase ("Domain research", "Email triage", \
        "Reading documentation", "Code review").
            * NEVER use these words alone or as the whole label: \
        "browsing", "browse", "web", "website", "internet", "online", "work", \
        "general", "stuff", "misc", "task", "thing", "app", "application". \
        These are too broad and defeat the purpose.
            * 1–4 words, max 60 characters. Title case is fine.
          - When uncertain, prefer reusing an existing name over inventing one.

        "summary": under 10 words describing what the user is doing right now.
          - If "privacy" is "none": describe the action, not the UI.
          - If "privacy" is ANYTHING OTHER THAN "none": the summary MUST describe \
        only the activity TYPE. Never include dollar amounts, counterparty \
        names, account numbers, client names, specific transaction details, \
        medication names, diagnoses, or salary figures. "Reviewing bank \
        statement" is fine; "Transferred $5000 to Acme LLC" is NOT.

        "sameAsBefore": true ONLY when this frame shows essentially the same \
        activity AND the same summary as the previous frame above. False if \
        the user has moved to a different tool, started a different sub-task, \
        or anything visibly meaningful has changed. Set to false when there \
        is no previous frame.

        "engagement": 0-100 estimate of active working intensity in THIS frame.
          80-100 = deep work (dense editing, debugging, focused problem solving)
          50-79  = steady work (reading docs, writing email, normal coding)
          20-49  = light engagement (scrolling, skimming, reviewing)
          0-19   = passive or idle (video playing, static screen, lock screen, desktop)

        "privacy": activity-sensitivity classification (separate from "safe"):
          - financial: the USER's own banking, crypto wallets, brokerage, \
        invoices they are paying or reviewing, bookkeeping/accounting apps, \
        bill-pay flows, payment processors showing personal balances. \
        NOT "financial": team budget spreadsheets at work, revenue dashboards, \
        Stripe docs/dashboard for the user's product, a GitHub PR that mentions \
        per-call pricing, any incidental currency or number.
          - personal_messages: DMs with friends or family in iMessage, \
        WhatsApp, personal email, personal Facebook/Instagram DMs. Work \
        Slack / Teams / work email is NOT this tag.
          - medical: patient records, therapy notes, lab results, prescriptions.
          - hr_legal: compensation sheets, performance reviews, candidate \
        pipelines, signed or draft contracts, legal correspondence.
          - none: everything else, including all normal work.

        When in doubt about a privacy tag, pick the tag — not "none". It is \
        safer to over-redact than to leak.

        "recognitionLevel" — VERY STRICT. The default is "none". This \
        field exists to capture moments worth quoting on a yearly review. \
        It is FAR better to under-fire than over-fire. A brag sheet loses \
        credibility if it cites routine politeness or ambient internet \
        text the user happens to be reading.

        Return "none" UNLESS the frame clearly shows BOTH (A) and (B):

        (A) DIRECT-CHANNEL CONTEXT — the praise lives in a channel where \
        the user is unambiguously a participant, with visible structural \
        evidence on screen. Examples that qualify:
          - A 1-on-1 DM where the message header shows the user's name \
        as the recipient.
          - A thread reply that explicitly addresses the user by name \
        ("@\(firstName)", "\(firstName), …", or the recipient \
        line of an email shows the user).
          - A comment on a document/PR/issue that the user authored, \
        replying to their work.
          - A public team channel post where the user is @-mentioned \
        and praised by name.

        Examples that DO NOT qualify (always "none"):
          - LinkedIn / Twitter / Mastodon / Bluesky / Reddit / Hacker \
        News / Medium / news / blog feeds. Reading other people's posts \
        is not recognition, even if those posts contain compliments \
        toward someone.
          - Public posts where the speaker is visible but the recipient \
        is unclear or generic ("for some it might be nostalgic", "great \
        job team", group thanks not naming the user).
          - The user's own outgoing messages, drafts, or sent items.
          - Quoted text inside an article.
          - AI-generated or boilerplate replies ("Thank you for your \
        message — we'll get back to you").
          - Sarcasm or backhanded compliments.

        (B) SPECIFIC, PERSONAL PRAISE — the message names a contribution \
        the user actually made, not generic civility. "thanks!" alone \
        is "none". "thank you so much" alone is "none". "looks good" \
        alone is "none". The praise has to point at a thing the user \
        did or made.

        Strength grading (only after (A) and (B) are both satisfied):
          - "weak": polite acknowledgement that names the contribution \
        in passing ("thanks for handling this — really helped").
          - "specific": names the contribution AND its impact ("the \
        analysis you ran saved us a week of work").
          - "major": unambiguous, often public, often quotable ("this \
        was outstanding work — exactly what we needed", a glowing \
        client email, a public shoutout that names the user).

        "recognitionQuote": when level != "none", extract the praise \
        text verbatim or lightly trimmed (drop greetings/sign-offs). \
        Cap at ~280 characters. Otherwise empty string.

        "recognitionSpeaker": when level != "none" AND a sender name is \
        clearly visible on screen as the AUTHOR of the praise message \
        (chat sender header, email "From:", comment author byline), \
        return that name. Do NOT use a name that's only visible as a \
        post author in a feed the user is browsing. Do NOT invent a \
        name from context. Empty string if uncertain.

        When in doubt: "none". Most frames are "none". The user wants \
        to trust this list.
        \(planningRules)

        JSON only. No explanations.
        """
    }

    // MARK: - JSON parsing

    func parseAnalysisJSON(_ raw: String) -> Outcome {
        // Models sometimes wrap JSON in ```json … ``` despite instructions.
        // Strip that before parsing.
        let cleaned = Self.stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("couldn't parse JSON: \(cleaned.prefix(80))")
        }

        // Fail-closed on any missing field — treat the frame as unsafe.
        guard let safe = obj["safe"] as? Bool else {
            return .failed("missing 'safe' field")
        }
        let categoryRaw = (obj["category"] as? String)?.lowercased() ?? "other"
        let category = FrameCategory(rawValue: categoryRaw) ?? .other
        let summary = ((obj["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Engagement might come back as Int or Double depending on the
        // model's whim. Accept either.
        let engagementRaw: Int
        if let i = obj["engagement"] as? Int {
            engagementRaw = i
        } else if let d = obj["engagement"] as? Double {
            engagementRaw = Int(d)
        } else {
            engagementRaw = 0
        }
        let engagement = max(0, min(100, engagementRaw))

        // Privacy tag. Missing or unrecognized values fall back to `none`
        // — we do NOT fail-closed here because an uncertain privacy tag
        // isn't a safety issue, and the `safe` check already guards leaks.
        let privacyRaw = (obj["privacy"] as? String)?.lowercased() ?? "none"
        let privacy = PrivacyTag(rawValue: privacyRaw) ?? .none

        // Activity fields. Both default to safe values when missing
        // so partial responses still produce a usable FrameAnalysis — the
        // recorder validates `activity` separately and falls back to the
        // category display name if the model's first attempt is too generic.
        let activityRaw = ((obj["activity"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sameAsBefore = (obj["sameAsBefore"] as? Bool) ?? false

        // Recognition fields. Default to .none / empty so
        // partial / older responses just don't contribute to the brag
        // sheet — they don't break the analyzer pipeline.
        let recognitionRaw = (obj["recognitionLevel"] as? String)?.lowercased() ?? "none"
        let recognitionLevel = RecognitionLevel(rawValue: recognitionRaw) ?? .none
        let recognitionQuote = ((obj["recognitionQuote"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recognitionSpeaker = ((obj["recognitionSpeaker"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Planning signals. Optional and never fail-closed; dropped for
        // frames tagged private, whatever the model returned.
        var conversation: ConversationSnapshot?
        var meetings: [MeetingMention] = []
        if privacy == .none {
            conversation = Self.parseConversation(obj["conversation"])
            meetings = Self.parseMeetings(obj["meetings"])
        }

        return .analyzed(FrameAnalysis(
            safe: safe,
            category: category,
            summary: summary,
            engagement: engagement,
            privacy: privacy,
            activity: activityRaw,
            sameAsBefore: sameAsBefore,
            recognitionLevel: recognitionLevel,
            recognitionQuote: recognitionQuote,
            recognitionSpeaker: recognitionSpeaker,
            conversation: conversation,
            meetings: meetings
        ))
    }

    private static func text(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func party(_ value: Any?) -> String? {
        let raw = text(value).lowercased()
        return raw == "me" || raw == "them" ? raw : nil
    }

    static func parseConversation(_ value: Any?) -> ConversationSnapshot? {
        guard let c = value as? [String: Any] else { return nil }
        let with = text(c["with"])
        guard !with.isEmpty else { return nil }
        let request = text(c["request"])
        return ConversationSnapshot(
            with: with,
            app: text(c["app"]).isEmpty ? nil : text(c["app"]),
            topic: text(c["topic"]),
            lastFrom: party(c["lastFrom"]),
            request: request.isEmpty ? nil : request,
            requestBy: request.isEmpty ? nil : party(c["requestBy"])
        )
    }

    static func parseMeetings(_ value: Any?) -> [MeetingMention] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.prefix(6).compactMap { m in
            let title = text(m["title"])
            let start = text(m["start"])
            guard !title.isEmpty, !start.isEmpty else { return nil }
            let with = text(m["with"])
            return MeetingMention(title: title, start: start, with: with.isEmpty ? nil : with)
        }
    }

    private static func stripCodeFence(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Drop first line ("```json" or "```")
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s
    }

    // MARK: - Image encoding

    /// Downscale → JPEG → base64. Anthropic's vision models resize images
    /// server-side above 8000 px on the longest side; we downscale to 1568
    /// (the recommended long-side) to save bandwidth and encode time.
    private static func encodeAsJPEG(image: CGImage, maxDimension: Int, quality: CGFloat) -> String? {
        let srcW = image.width
        let srcH = image.height
        let longest = max(srcW, srcH)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1.0
        let targetW = max(1, Int(Double(srcW) * scale))
        let targetH = max(1, Int(Double(srcH) * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

        guard let ctx = CGContext(data: nil,
                                  width: targetW,
                                  height: targetH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data,
                                                          UTType.jpeg.identifier as CFString,
                                                          1,
                                                          nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, scaled, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }
}
