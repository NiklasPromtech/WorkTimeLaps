import Foundation

/// Asks Claude to write a day's diary entry from its text log.
///
/// Only text is sent: the stats, the condensed activity timeline (labels and
/// one-line summaries the frame analyzer already produced — generic for
/// private frames), any recognition quotes and the user's own session
/// notes. No screenshots.
///
/// Raw HTTP against the Messages API (there's no official Swift SDK), with
/// streaming, structured output (a JSON schema), and server-side fallback:
/// if the model declines on policy grounds, the API retries on its
/// recommended fallback model inside the same call.
struct DiaryWriter: Sendable {

    static let defaultModel = "claude-opus-5-5"

    enum WriterError: LocalizedError {
        case http(status: Int, message: String)
        case refused
        case truncated
        case badResponse(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                switch status {
                case 401: return "The Anthropic API key was rejected (HTTP 401)."
                case 429: return "Rate limited by the Anthropic API — will try again later."
                case 529: return "The Anthropic API is overloaded — will try again later."
                default: return "Anthropic API error (HTTP \(status)): \(message)"
                }
            case .refused: return "Claude declined to write this entry."
            case .truncated: return "The response was cut off before it finished."
            case .badResponse(let why): return "Unexpected response from the API: \(why)"
            case .network(let why): return "Network error: \(why)"
            }
        }
    }

    /// What Claude returns, before local stats are attached.
    struct Draft: Decodable, Sendable {
        let headline: String
        let entry: [String]
        let highlights: [String]
        let timeline: [WorkDiary.TimelineItem]
        let looseEnds: [String]
        let dayShape: WorkDiary.DayShape
    }

    let apiKey: String
    var model: String = DiaryWriter.defaultModel

    /// Writes the entry. Returns the draft and the model that produced it
    /// (which differs from `model` if the request fell back).
    func write(_ material: DayMaterial) async throws -> (draft: Draft, model: String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        // Idle timeout between streamed chunks; the stream sends pings.
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            model: model,
            prompt: DiaryComposer.promptText(for: material)
        ))

        let (text, servedModel, stopReason) = try await stream(request)

        switch stopReason {
        case "refusal": throw WriterError.refused
        case "max_tokens": throw WriterError.truncated
        default: break
        }
        guard let data = text.data(using: .utf8), !text.isEmpty else {
            throw WriterError.badResponse("no text in the response")
        }
        do {
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            return (draft, servedModel ?? model)
        } catch {
            throw WriterError.badResponse("couldn't decode the entry (\(error.localizedDescription))")
        }
    }

    // MARK: - Request

    static func requestBody(model: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            // Thinking counts toward max_tokens; the entry itself is ~1-2k.
            "max_tokens": 16000,
            "stream": true,
            "system": systemPrompt,
            "fallbacks": "default",
            "output_config": [
                "effort": "medium",
                "format": [
                    "type": "json_schema",
                    "schema": schema
                ]
            ],
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
    }

    static let systemPrompt = """
    You write a short, honest work diary entry for one person, in their voice, from an automatic log of their screen activity. The log comes from WorkTimeLaps, a macOS app that labels a screenshot every 10 seconds; you never see the screenshots themselves.

    Voice: first person, past tense, plain and warm, like a thoughtful person's own end-of-day notes. No hype, no productivity-coach tone, no emoji, no headings inside the text.

    Stay grounded in the log:
    - Activity labels and summaries are machine-generated and can be vague or wrong. Trust patterns across many lines over any single line, and never invent people, results, meetings or decisions the log doesn't show.
    - Use times and durations sparingly and roughly ("most of the morning", "about two hours").
    - Lines marked private were redacted on purpose. Mention them only generically ("some personal admin", "a private conversation") and never guess what they were.
    - Quotes under <recognition> are real messages the person received. Mention them warmly, quoting at most one short phrase.
    - The person's own notes under <notes> are the most reliable source. Weave them in.

    Fields:
    - headline: 3 to 9 words on what the day was about, sentence case, no final period.
    - entry: 2 to 4 short paragraphs, 90 to 220 words in total, telling the day in order.
    - highlights: 2 to 5 concrete things that got done or moved forward, each under 14 words.
    - timeline: 4 to 10 entries for the main stretches of the day, in order. start and end are 24-hour HH:MM times taken from the log; title is 2 to 5 words; detail is one short sentence; category is the dominant category.
    - looseEnds: up to 4 things that look unfinished or worth picking up next, each under 14 words. Leave it empty when nothing clearly qualifies.
    - dayShape: deep_focus, steady, collaborative, scattered or light.
    """

    static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["headline", "entry", "highlights", "timeline", "looseEnds", "dayShape"],
            "properties": [
                "headline": ["type": "string"],
                "entry": ["type": "array", "items": ["type": "string"]],
                "highlights": ["type": "array", "items": ["type": "string"]],
                "timeline": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["start", "end", "title", "detail", "category"],
                        "properties": [
                            "start": ["type": "string"],
                            "end": ["type": "string"],
                            "title": ["type": "string"],
                            "detail": ["type": "string"],
                            "category": ["type": "string", "enum": FrameCategory.allCases.map(\.rawValue)]
                        ]
                    ]
                ],
                "looseEnds": ["type": "array", "items": ["type": "string"]],
                "dayShape": ["type": "string", "enum": WorkDiary.DayShape.allCases.map(\.rawValue)]
            ]
        ]
    }

    // MARK: - Streaming

    /// Sends the request and assembles the streamed text. Returns the text,
    /// the model that served the response, and the stop reason.
    private func stream(_ request: URLRequest) async throws -> (String, String?, String?) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw WriterError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WriterError.badResponse("no HTTP response")
        }

        if http.statusCode != 200 {
            var body = ""
            do {
                for try await line in bytes.lines {
                    body += line
                    if body.count > 2000 { break }
                }
            } catch {}
            throw WriterError.http(status: http.statusCode, message: Self.errorMessage(fromBody: body))
        }

        var parser = SSEParser()
        do {
            for try await line in bytes.lines {
                try parser.consume(line: line)
                if parser.isFinished { break }
            }
        } catch let error as WriterError {
            throw error
        } catch {
            throw WriterError.network(error.localizedDescription)
        }
        return (parser.text, parser.servedModel, parser.stopReason)
    }

    static func errorMessage(fromBody body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(body.prefix(200))
    }
}

/// Incremental parser for the Messages API's server-sent events. Collects
/// text blocks in order, the serving model and the stop reason.
struct SSEParser {
    private(set) var servedModel: String?
    private(set) var stopReason: String?
    private(set) var isFinished = false
    private var textByIndex: [Int: String] = [:]

    /// All text blocks, in content order. After a mid-stream fallback the
    /// fallback model continues from the partial text, so concatenating the
    /// blocks yields the complete output.
    var text: String {
        textByIndex.keys.sorted().compactMap { textByIndex[$0] }.joined()
    }

    mutating func consume(line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any], let model = message["model"] as? String {
                servedModel = model
            }
        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return }
            if blockType == "text" {
                textByIndex[index] = (block["text"] as? String) ?? ""
            } else if blockType == "fallback",
                      let to = block["to"] as? [String: Any],
                      let model = to["model"] as? String {
                servedModel = model
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String else { return }
            textByIndex[index, default: ""] += piece
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
        case "message_stop":
            isFinished = true
        case "error":
            let error = event["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? "error"
            let message = error?["message"] as? String ?? "stream error"
            let status = kind == "overloaded_error" ? 529 : (kind == "rate_limit_error" ? 429 : 500)
            throw DiaryWriter.WriterError.http(status: status, message: message)
        default:
            break
        }
    }
}
