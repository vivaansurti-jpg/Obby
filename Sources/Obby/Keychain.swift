import Foundation
import Security

// Cloud API keys live only in the macOS Keychain (generic password items), never in
// UserDefaults, notes, or files. Accounts are provider identifiers such as "anthropic".
enum Keychain {
    static let service = "local.obby.notes.ai-provider"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    /// Checks for an item without reading its secret, so it never triggers an access prompt.
    static func exists(_ account: String) -> Bool {
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Obby AI provider key (\(account))"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ObbyError("Couldn’t save the API key to Keychain (error \(added)).") }
        } else if status != errSecSuccess {
            throw ObbyError("Couldn’t update the API key in Keychain (error \(status)).")
        }
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
