import Foundation
import os
import Security

enum KeychainReader {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "Keychain")

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

    /// Saves by deleting the item and adding it fresh, never by updating it in place
    /// (2026-10-04). An in-place update keeps the item's existing access list, so an item
    /// pre-planted under Kannu's service and account with a permissive list would have received
    /// the secret; a fresh add gets a list that trusts only Kannu. Writes only Kannu-owned
    /// services — another app's item is read-only. `KeychainWritePlan` decides both, and
    /// `KeychainWritePlanTests` keeps in-place updates out of the app.
    ///
    /// Delete-then-add is not atomic, so the prior value is read first (silently: a save runs on
    /// every keystroke and must never raise a keychain prompt) and re-added if the fresh add fails.
    /// A failed save therefore keeps the secret the user had, as the old in-place update did; only
    /// a prior value Kannu cannot read without a prompt is not restored. Logs the OSStatus, never
    /// the value.
    @discardableResult
    static func setGenericPassword(_ value: String, service: String, account: String) -> Bool {
        guard KeychainWritePlan.forSaving(service: service) == .recreate else { return false }
        let prior = read(service: service, account: account, allowInteraction: false).value
        guard deleteGenericPassword(service: service, account: account) else { return false }
        let status = addGenericPassword(value, service: service, account: account)
        if status == errSecSuccess { return true }
        log.error("Keychain save of \(account, privacy: .public) failed: OSStatus \(status, privacy: .public)")
        if let restore = KeychainWritePlan.valueToRestore(afterAdd: status, prior: prior) {
            let restored = addGenericPassword(restore, service: service, account: account)
            log.error("Keychain restore of \(account, privacy: .public) after the failed save: OSStatus \(restored, privacy: .public)")
        }
        return false
    }

    /// A fresh item: `SecItemAdd` gives it an access list that trusts only Kannu. Called only by
    /// `setGenericPassword`, after the delete — never on its own.
    private static func addGenericPassword(_ value: String, service: String, account: String) -> OSStatus {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// True when nothing is left at this service and account. Refuses (false) for a service
    /// Kannu does not own: deleting another app's credentials is a write too.
    @discardableResult
    static func deleteGenericPassword(service: String, account: String) -> Bool {
        guard KeychainWritePlan.isKannuOwned(service: service) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return KeychainWritePlan.deleteLeftNothing(SecItemDelete(query as CFDictionary))
    }
}
