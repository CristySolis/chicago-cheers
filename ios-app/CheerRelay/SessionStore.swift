import Foundation
import Security

/// Keeps the runner's refresh token in the Keychain — never the password, and
/// never UserDefaults, which isn't encrypted.
///
/// The token is replaced on every refresh, and the login provider may revoke
/// the whole session if a replaced one is ever used again. So the new token is
/// saved here before anything else uses the session it came with.
nonisolated enum SessionStore {

    private static let service = "com.cristysolis.Cheery.session"
    private static let account = "refresh_token"

    static var refreshToken: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(refreshToken: String) {
        let data = Data(refreshToken.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            // Readable once the phone has been unlocked since boot, so a sync
            // started before the screen locks can finish.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
