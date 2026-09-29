import Foundation
import Security

/// Stores the Anthropic API key in the login keychain.
///
/// Earlier versions kept the key in plaintext UserDefaults; it's moved to
/// the keychain (and deleted from preferences) the first time it's read.
///
/// The item's access list is tied to the app's signing identity. Builds
/// signed ad hoc look like a new app each time, so macOS asks once after a
/// rebuild whether WorkTimeLaps may read it — choose "Always Allow".
@MainActor
enum APIKeyStore {

    private static let service = "WorkTimeLaps"
    private static let account = "anthropic-api-key"
    private static let legacyDefaultsKey = "anthropic_api_key"

    /// In-memory copy so the keychain is read once per launch, not every
    /// time a menu or settings view refreshes.
    private static var cached: String??

    static func load() -> String? {
        if let cached { return cached }
        migrateLegacyKeyIfNeeded()
        let value = readKeychain()
        cached = .some(value)
        return value
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        if writeKeychain(trimmed) {
            cached = .some(trimmed)
            NotificationCenter.default.post(name: .worktimelapsAPIKeyChanged, object: nil)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        cached = .some(nil)
        NotificationCenter.default.post(name: .worktimelapsAPIKeyChanged, object: nil)
    }

    /// Short fingerprint for the UI — first 4 chars + "…" + last 4 chars.
    /// Never returns the full key.
    static func fingerprint(of key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                NSLog("WorkTimeLaps: keychain read failed (\(status))")
            }
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private static func writeKeychain(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "WorkTimeLaps — Anthropic API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("WorkTimeLaps: keychain write failed (\(status))")
        }
        return status == errSecSuccess
    }

    /// Moves a key saved by an earlier version out of plaintext preferences.
    private static func migrateLegacyKeyIfNeeded() {
        guard let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if legacy.isEmpty || writeKeychain(legacy) {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }
}
