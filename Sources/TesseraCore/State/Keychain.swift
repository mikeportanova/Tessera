import Foundation
import Security

/// Minimal Keychain wrapper for the single secret Tessera stores: the Anthropic API key.
/// Uses a generic password item keyed by service + account.
public enum Keychain {
    private static let service = "com.fileread.Tessera"
    private static let account = "anthropic-api-key"

    public static func setAPIKey(_ key: String) {
        let data = Data(key.utf8)
        // Delete any existing item first so we can cleanly re-add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard !key.isEmpty else { return }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public static var hasAPIKey: Bool { apiKey() != nil }
}
