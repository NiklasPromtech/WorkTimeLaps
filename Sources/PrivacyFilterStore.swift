import Foundation

/// Which privacy tags should trigger visual redaction.
///
/// Kept in UserDefaults as an array of raw strings. A frame whose
/// `FrameAnalysis.privacy` matches any enabled tag has its image replaced
/// with the REDACTED placeholder in the MP4 — but the sidecar/journal
/// still records the category and (sanitized) summary, so the activity
/// log stays complete even though the video doesn't.
///
/// Default on first launch: every selectable tag enabled. Niklas's
/// framing is "err on the side of redact; the log describes what I did
/// without leaking specifics," and the analyzer prompt is written to
/// match (generic summaries whenever privacy != none).
enum PrivacyFilterStore {

    private static let defaultsKey = "WorkTimeLaps.privacyFilters.enabledTags"
    /// Bumped whenever the default set changes, so existing installs can
    /// opt in to new tags automatically the first time they see them.
    private static let versionKey  = "WorkTimeLaps.privacyFilters.defaultsVersion"
    private static let currentDefaultsVersion = 1

    /// Seeds defaults on first launch (or when we ship a new default set).
    /// Safe to call repeatedly.
    static func ensureDefaults() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        if stored >= currentDefaultsVersion {
            return
        }
        let tags = PrivacyTag.selectable.map { $0.rawValue }
        UserDefaults.standard.set(tags, forKey: defaultsKey)
        UserDefaults.standard.set(currentDefaultsVersion, forKey: versionKey)
    }

    /// Currently-enabled tags as a Set for fast membership checks in the
    /// capture loop.
    static var enabled: Set<PrivacyTag> {
        ensureDefaults()
        let raws = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(raws.compactMap { PrivacyTag(rawValue: $0) })
    }

    static func isEnabled(_ tag: PrivacyTag) -> Bool {
        enabled.contains(tag)
    }

    static func setEnabled(_ tag: PrivacyTag, _ on: Bool) {
        ensureDefaults()
        var current = enabled
        if on {
            current.insert(tag)
        } else {
            current.remove(tag)
        }
        let raws = current.map { $0.rawValue }.sorted()
        UserDefaults.standard.set(raws, forKey: defaultsKey)
    }

    /// Returns true when the user has asked for a frame with this tag to be
    /// redacted. `.none` always returns false — it's the absence of a tag,
    /// not a filter.
    static func shouldRedact(_ tag: PrivacyTag) -> Bool {
        guard tag != .none else { return false }
        return isEnabled(tag)
    }
}
