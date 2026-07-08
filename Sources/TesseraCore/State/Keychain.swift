import Foundation
import Security

/// Minimal Keychain wrapper for the single secret Tessera stores: the Anthropic API key.
/// Uses a generic password item keyed by service + account.
public enum Keychain {
    private static let service = "com.fileread.Tessera"
    private static let account = "anthropic-api-key"

    /// Store (or clear, when empty) the API key. Whitespace/newlines are trimmed — a pasted key
    /// often carries a trailing newline that would break authentication. Returns whether the
    /// keychain now reflects the request; callers that ignore it can consult `hasAPIKey`.
    @discardableResult
    public static func setAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Delete any existing item first so we can cleanly re-add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            NSLog("[Tessera] Keychain delete failed (\(deleteStatus))")
        }

        guard !trimmed.isEmpty else {
            return deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        }

        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("[Tessera] Keychain add failed (\(addStatus))")
        }
        return addStatus == errSecSuccess
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // errSecItemNotFound simply means no key is set. Any other failure (e.g. a locked keychain)
        // also returns nil, so planning degrades to the offline fallback rather than erroring.
        if status != errSecSuccess, status != errSecItemNotFound {
            NSLog("[Tessera] Keychain read failed (\(status))")
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public static var hasAPIKey: Bool { apiKey() != nil }
}
