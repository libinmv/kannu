import Foundation
import Security

enum KeychainReader {
    static func genericPassword(service: String, account: String? = nil) -> String? {
        read(service: service, account: account).value
    }

    /// Reads a generic password and reports the raw status so callers can tell
    /// "item missing" apart from "item exists but macOS wants the user to approve access".
    /// `allowInteraction: false` suppresses the system permission dialog entirely — items
    /// owned by another app then fail with errSecInteractionNotAllowed/errSecUserCanceled
    /// instead of blocking a background refresh behind a prompt nobody asked for.
    static func read(
        service: String,
        account: String? = nil,
        allowInteraction: Bool = true
    ) -> (value: String?, status: OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account } // only filter by account when given
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    /// True when the item is present but macOS blocked the read pending user approval.
    /// `errSecAuthFailed` is deliberately excluded: it means the item itself is broken
    /// (wrong ACL, corrupted entry), and offering an "approve access" button for it gives
    /// the user a control that cannot help.
    static func needsUserApproval(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecUserCanceled
    }

    @discardableResult
    static func setGenericPassword(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func deleteGenericPassword(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
