import Foundation

/// One entry in the rolling activity vocabulary. The model is fed the
/// recent ones on every frame so it can reuse a name verbatim instead of
/// rephrasing — that's what makes downstream clustering ("you spent 12 min
/// on Stripe pricing") tractable.
///
/// `examples` carries the last few summaries that landed in this bucket so
/// the prompt has more than just a label to anchor reuse. Three is plenty.
struct ActivityEntry: Codable, Sendable, Equatable {
    let name: String
    var firstUsed: Date
    var lastUsed: Date
    var useCount: Int
    var examples: [String]
}

/// Rolling 2-hour vocabulary of activities the analyzer has emitted. Stored
/// at `~/Movies/WorkTimeLaps/_journal/activities.json` so it survives
/// quota-driven MP4 pruning. Entries older than `windowDuration` are
/// filtered out of the prompt and pruned from disk on each write.
///
/// Why time-windowed instead of all-time:
///   - Bounded prompt size (5–15 entries typical, ~hundreds of tokens).
///   - Bad labels self-heal — if "browsing" sneaks in, it ages out in 2 h.
///   - Prompt-injection blast radius is small for the same reason.
///   - We trade week-over-week consistency for "no maintenance ever needed."
///
/// Not actor-isolated. File I/O is synchronous and small; matches the
/// pattern Journal.swift uses.
enum ActivityVocabulary {

    /// How long an entry stays in the rolling window before it's pruned.
    /// Two hours is the default; tweak here if it ever feels too aggressive.
    static let windowDuration: TimeInterval = 2 * 60 * 60

    /// Cap on how many summary examples we keep per entry.
    private static let maxExamplesPerEntry = 3

    /// Hard cap on how many entries we ever return in the prompt — defense
    /// against a runaway day. If the model creates many distinct labels in
    /// a short window we still cap the prompt size.
    private static let maxEntriesInPrompt = 30

    /// Words/phrases that auto-reject a returned activity name. Goal is to
    /// keep labels specific (Stripe, Lovable) rather than generic
    /// (browsing, work). Matched case-insensitively as whole words.
    static let deniedWords: Set<String> = [
        "browsing", "browse",
        "work", "working",
        "general", "stuff", "misc", "miscellaneous",
        "web", "website", "internet", "online",
        "app", "application", "task", "thing"
    ]

    /// Max characters in a returned activity name. Keeps overly long
    /// model gibberish from polluting the vocabulary.
    private static let maxNameLength = 60

    private static var fileURL: URL {
        Journal.folder.appendingPathComponent("activities.json")
    }

    // MARK: - Reading

    /// Returns entries used within the last `windowDuration`, sorted by
    /// most-recently-used first, capped at `maxEntriesInPrompt`. This is
    /// the slice the analyzer prompt sees.
    static func recent(now: Date = Date()) -> [ActivityEntry] {
        let all = loadAll()
        let cutoff = now.addingTimeInterval(-windowDuration)
        let active = all.filter { $0.lastUsed >= cutoff }
        let sorted = active.sorted(by: { $0.lastUsed > $1.lastUsed })
        return Array(sorted.prefix(maxEntriesInPrompt))
    }

    // MARK: - Writing

    /// Records use of an activity name with the summary that came along
    /// with it. If `name` is new, creates an entry; otherwise bumps usage
    /// and appends the summary as an example. Prunes expired entries on
    /// the same write.
    static func record(name: String, summary: String, now: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var entries = loadAll()
        let cutoff = now.addingTimeInterval(-windowDuration)
        // Prune expired up front.
        entries.removeAll { $0.lastUsed < cutoff }

        if let idx = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            var entry = entries[idx]
            entry.lastUsed = now
            entry.useCount += 1
            // Keep examples deduplicated and bounded.
            let summaryTrimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summaryTrimmed.isEmpty,
               !entry.examples.contains(where: { $0.caseInsensitiveCompare(summaryTrimmed) == .orderedSame }) {
                entry.examples.insert(summaryTrimmed, at: 0)
                if entry.examples.count > maxExamplesPerEntry {
                    entry.examples = Array(entry.examples.prefix(maxExamplesPerEntry))
                }
            }
            entries[idx] = entry
        } else {
            let summaryTrimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(ActivityEntry(
                name: trimmed,
                firstUsed: now,
                lastUsed: now,
                useCount: 1,
                examples: summaryTrimmed.isEmpty ? [] : [summaryTrimmed]
            ))
        }

        saveAll(entries)
    }

    // MARK: - Validation

    /// Sanitizes a candidate activity name returned by the model. Returns a
    /// cleaned version on success, or `nil` when the candidate violates
    /// the shape rules (empty, too long, contains a denied word, looks
    /// non-activity-like). The recorder uses this to fall back on the
    /// category display name when the model's first attempt is too generic.
    static func validate(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxNameLength else { return nil }

        // Tokenize on whitespace and punctuation; reject if any token is
        // in the denied set. We split on a permissive set so "browsing,"
        // and "browsing" both get caught.
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let tokens = trimmed
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        // Reject if the candidate is *only* denied words. A label like
        // "Email triage" should pass — "email" alone wouldn't be denied,
        // and the second token gives it specificity. A label like "general
        // browsing" should fail because every token is denied.
        if !tokens.isEmpty && tokens.allSatisfy({ deniedWords.contains($0) }) {
            return nil
        }

        // Also reject if the *whole label* exactly matches a denied word.
        // (Catches "Browsing" returned alone with capitalisation.)
        if deniedWords.contains(trimmed.lowercased()) {
            return nil
        }

        return trimmed
    }

    // MARK: - Disk I/O

    /// Loads everything currently on disk, with no pruning. Recent() and
    /// record() both filter on top of this.
    static func loadAll() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([ActivityEntry].self, from: data)) ?? []
    }

    private static func saveAll(_ entries: [ActivityEntry]) {
        // Make sure the journal directory exists (it does after first
        // recording, but on a totally fresh install we might be writing
        // here before any session has finished).
        _ = Journal.folder
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WorkTimeLaps: activity vocabulary write failed: \(error.localizedDescription)")
        }
    }

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
}
