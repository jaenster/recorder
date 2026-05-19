import Foundation
import Security

/// Tiny Keychain helper for storing the OpenAI API key (and any other small
/// secrets we might add later). UserDefaults would leave it in plaintext in
/// ~/Library/Preferences/; Keychain stores it encrypted behind the user's
/// login keychain.
enum Keychain {
    private static let service = "info.stoots.recorder"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // SecItemUpdate first; if not found, SecItemAdd.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let st = SecItemUpdate(attrs as CFDictionary, updateAttrs as CFDictionary)
        if st == errSecItemNotFound {
            var addAttrs = attrs
            addAttrs[kSecValueData as String] = data
            SecItemAdd(addAttrs as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &item)
        guard st == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
