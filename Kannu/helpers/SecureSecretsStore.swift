import Defaults
import Foundation

enum SecureSecretKey: String, CaseIterable {
    case spotifySPDCCookie = "spotify-sp-dc-cookie"
    case geminiAPIKey = "gemini-api-key"
    case openaiAPIKey = "openai-api-key"
    case claudeAPIKey = "claude-api-key"
    case groqAPIKey = "groq-api-key"
    case pushoverUserKey = "pushover-user-key"
    case pushoverAppToken = "pushover-app-token"
    case webhookURL = "agent-status-webhook-url"
    /// Brain › Tasks › Sources › Jira Cloud: `JiraCredential` as JSON (`{email, site, token}`), so
    /// the token and the one host it may be sent to are stored, and read, together.
    case jiraCredential = "jira-credential"
}

enum SecureSecretsStore {
    private static let service = "com.kannu.app.secure-secrets"

    static func value(for key: SecureSecretKey) -> String {
        KeychainReader.genericPassword(service: service, account: key.rawValue) ?? ""
    }

    /// The value and the raw status, so a caller can tell a missing item from one macOS wants the
    /// user to approve. `allowInteraction: false` never shows the Keychain dialog: a read that would
    /// need it fails with a status `KeychainReader.needsUserApproval` recognises. Either way this
    /// can block, so call it off the main actor.
    static func read(_ key: SecureSecretKey, allowInteraction: Bool) -> (value: String?, status: OSStatus) {
        KeychainReader.read(service: service, account: key.rawValue, allowInteraction: allowInteraction)
    }

    @discardableResult
    static func set(_ value: String, for key: SecureSecretKey) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return removeValue(for: key)
        }
        return KeychainReader.setGenericPassword(trimmed, service: service, account: key.rawValue)
    }

    @discardableResult
    static func removeValue(for key: SecureSecretKey) -> Bool {
        KeychainReader.deleteGenericPassword(service: service, account: key.rawValue)
    }

    /// Move legacy plaintext values from Defaults to Keychain.
    static func migrateFromDefaultsIfNeeded() {
        migrate(defaultsKey: .spotifySPDCCookie, secureKey: .spotifySPDCCookie)
        migrate(defaultsKey: .geminiApiKey, secureKey: .geminiAPIKey)
        migrate(defaultsKey: .openaiApiKey, secureKey: .openaiAPIKey)
        migrate(defaultsKey: .claudeApiKey, secureKey: .claudeAPIKey)
        migrate(defaultsKey: .groqApiKey, secureKey: .groqAPIKey)
        migrate(defaultsKey: .agentStatusPushoverUserKey, secureKey: .pushoverUserKey)
        migrate(defaultsKey: .agentStatusPushoverAppToken, secureKey: .pushoverAppToken)
        migrate(defaultsKey: .agentStatusWebhookURL, secureKey: .webhookURL)
    }

    private static func migrate(defaultsKey: Defaults.Key<String>, secureKey: SecureSecretKey) {
        let legacy = Defaults[defaultsKey].trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = value(for: secureKey)
        if existing.isEmpty, !legacy.isEmpty {
            set(legacy, for: secureKey)
        }
        if !legacy.isEmpty {
            Defaults[defaultsKey] = ""
        }
    }
}
