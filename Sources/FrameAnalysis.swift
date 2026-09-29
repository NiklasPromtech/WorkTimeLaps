import Foundation

/// Fixed vocabulary of activity categories. A closed list — instead of free
/// text — is what lets the UI color-code and aggregate cleanly across weeks
/// and months of recordings. If we ever want a new bucket it's a deliberate
/// decision, not a random model hallucination.
enum FrameCategory: String, Sendable, Codable, CaseIterable {
    case coding
    case writing
    case email
    case chat
    case meeting
    case browsing
    case design
    case terminal
    case reading
    case media
    case other

    /// Unknown values (a newer build's category, a hand edit) decode as
    /// `.other` instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FrameCategory(rawValue: raw.lowercased()) ?? .other
    }

    /// Display-friendly capitalization for menu labels.
    var display: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Rough "how active is this category by nature" weight, 0-1. Used as a
    /// sanity floor/ceiling on the model's own engagement estimate so the
    /// needle stays honest when it drifts — e.g. the model saying 75 on a
    /// Slack window gets pulled down toward the chat ceiling.
    var activityWeight: Double {
        switch self {
        case .coding, .writing, .terminal, .design: return 1.0
        case .email, .reading:                      return 0.7
        case .meeting:                              return 0.6
        case .chat, .browsing:                      return 0.4
        case .media:                                return 0.1
        case .other:                                return 0.5
        }
    }
}

/// Privacy / sensitivity classification. Separate from `safe` (which is
/// about credentials) — this is about content that's not a leak per se but
/// is still stuff the user doesn't want showing up in a video later.
///
/// Edge cases (a GitHub PR that mentions "$0.003 per call", a team budget
/// spreadsheet, revenue dashboards at work) are explicitly NOT `financial`
/// — the rule is "the user's own personal or business finances," not any
/// appearance of numbers or currency.
enum PrivacyTag: String, Sendable, Codable, CaseIterable {
    case none
    case financial          // banking, crypto, brokerage, invoices, accounting, bill pay
    case personal_messages  // DMs with friends/family; NOT work chat
    case medical            // patient records, therapy notes, lab results, prescriptions
    case hr_legal           // compensation, performance reviews, hiring pipelines, contracts

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PrivacyTag(rawValue: raw.lowercased()) ?? .none
    }

    /// Short label for the settings UI.
    var display: String {
        switch self {
        case .none:               return "None"
        case .financial:          return "Financial"
        case .personal_messages:  return "Personal messages"
        case .medical:            return "Medical"
        case .hr_legal:           return "HR & legal"
        }
    }

    /// Longer explanation shown under each checkbox in Settings.
    var blurb: String {
        switch self {
        case .none:
            return "No sensitive content detected."
        case .financial:
            return "Banking, crypto wallets, brokerage, invoices, accounting, bill pay, payment processors."
        case .personal_messages:
            return "Direct messages with friends or family (iMessage, WhatsApp, personal email). Work chat is not included."
        case .medical:
            return "Patient records, therapy notes, lab results, prescriptions."
        case .hr_legal:
            return "Compensation sheets, performance reviews, hiring pipelines, contracts, legal correspondence."
        }
    }

    /// The tags the settings UI shows. `none` is excluded because it's the
    /// absence of a filter, not a filter itself.
    static var selectable: [PrivacyTag] {
        allCases.filter { $0 != .none }
    }
}

/// Everything one Claude Haiku call returns about a single frame.
///
/// Five "always present" signals (safe / category / summary / engagement /
/// privacy) plus newer ones:
/// - `activity` — granular, free-text label like "Stripe pricing config"
///   or "Domain research" that's clustered into the activity stream.
///   Drawn from a 2-hour rolling vocabulary so the label stays stable
///   frame-to-frame and across short pauses.
/// - `sameAsBefore` — a hint from the model that this frame is showing
///   essentially the same activity as the previous one. When true the
///   recorder copies the previous frame's `activity` and `summary`
///   verbatim instead of trusting the new strings, which keeps the
///   cluster stable even if Haiku rephrases slightly.
/// - `recognition*` — if the frame shows a real person praising the user
///   for a specific contribution, the analyzer extracts the quote and
///   the speaker's name. Powers the Highlights / brag-sheet feature
///   — see Recognition.swift.
///
/// Safety and privacy are *always* re-evaluated, never inherited via
/// `sameAsBefore` — a transient credential flash needs to be caught even
/// when the surrounding activity didn't change.
struct FrameAnalysis: Sendable, Codable {
    let safe: Bool
    let category: FrameCategory
    let summary: String
    /// Per-frame raw engagement, 0-100. TimeLapseRecorder smooths this over
    /// a rolling window before showing it to the user.
    let engagement: Int
    /// Sensitivity tag. When the user has enabled the matching filter, the
    /// frame image is redacted — but the summary (which the prompt keeps
    /// deliberately generic for non-none frames) still gets logged.
    let privacy: PrivacyTag
    /// Granular, free-text activity label. May be empty when the model
    /// returned something that failed validation; the recorder falls back
    /// to the category display name in that case.
    let activity: String
    /// True when the model judges this frame to show the same activity as
    /// the previous one. Lets the recorder skip the rephrase noise and
    /// reuse the previous label/summary verbatim.
    let sameAsBefore: Bool

    // MARK: - Recognition signal

    /// Strength of the recognition / praise / compliment detected in this
    /// frame. `.none` for the vast majority of frames — only set higher
    /// when the model's strict rubric fires.
    let recognitionLevel: RecognitionLevel
    /// The actual quote, lightly trimmed of greetings/sign-offs. Empty
    /// when `recognitionLevel == .none`.
    let recognitionQuote: String
    /// Best-guess of who said it (sender name from the chat / email
    /// header on screen). Empty when not extractable.
    let recognitionSpeaker: String

    // MARK: - Planning signals

    /// A work conversation on screen, with any request still waiting on
    /// someone. Nil when no conversation is visible, and always nil for
    /// frames tagged with a privacy category.
    var conversation: ConversationSnapshot? = nil

    /// Upcoming meetings visible on screen (calendar, invite, email).
    var meetings: [MeetingMention] = []
}

/// A conversation seen on screen — who it's with, what it's about, and
/// whether a request is waiting on someone. The morning brief turns these
/// into follow-ups ("You asked Peter to get back to you about Erik").
struct ConversationSnapshot: Codable, Sendable, Hashable {
    /// The other person, or the channel/group name.
    let with: String
    /// Where the conversation is (Slack, LinkedIn, Gmail…).
    let app: String?
    /// What it's about, a few words.
    let topic: String
    /// Who wrote the most recent visible message: "me" or "them".
    let lastFrom: String?
    /// An unanswered ask as a short action ("Peter to get back about Erik").
    let request: String?
    /// Who made that ask: "me" (the user is waiting on them) or "them" (the
    /// user owes it).
    let requestBy: String?

    var hasOpenRequest: Bool {
        !(request ?? "").isEmpty && (requestBy == "me" || requestBy == "them")
    }
}

/// An upcoming meeting seen on screen.
struct MeetingMention: Codable, Sendable, Hashable {
    let title: String
    /// Local start time, "yyyy-MM-dd'T'HH:mm", as read from the screen.
    let start: String
    /// Attendee or organizer names, when shown.
    let with: String?

    /// The start as a date in the current time zone, if it parses.
    var startDate: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: start)
    }
}
