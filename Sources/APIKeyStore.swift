import Foundation

/// Persists the Anthropic API key between launches.
///
/// Currently backed by UserDefaults — the key lives in plaintext in
/// `~/Library/Preferences/com.niklas.worktimelaps.plist`. That's acceptable
/// for a local personal utility, but note: anyone with file-system access
/// to your user account can read it. If you want stronger protection,
/// swap the implementation to Security.framework (SecItemAdd / SecItemCopy).
enum APIKeyStore {
    private static let defaultsKey = "anthropic_api_key"

    static func load() -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Short fingerprint for the UI — first 4 chars + "…" + last 4 chars.
    /// Never returns the full key.
    static func fingerprint(of key: String) -> String {
        guard key.count > 12 else { return "••••" }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
