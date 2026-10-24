import Defaults
import Foundation
import Security

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
    /// Brain › Tasks › Sources › GitLab: `GitLabCredential` as JSON (`{baseURL, token}`), so the
    /// personal access token and the one server it may be sent to are stored, and read, together.
    case gitlabCredential = "gitlab-credential"
    /// Brain › Tasks › GitHub: `GitHubCredential` as JSON (`{baseURL, token}`), github.com or a GitHub
    /// Enterprise Server, so the token and the one server it may be sent to are stored together.
    case githubCredential = "github-credential"
    /// Brain › Tasks › Linear: `LinearCredential` as JSON (`{apiKey, workspace}`), so the API key and
    /// the workspace it belongs to are stored together.
    case linearCredential = "linear-credential"
    /// Brain › Tasks › Todoist: `TodoistCredential` as JSON (`{token, userID}`), so the API token and
    /// the account it belongs to are stored together.
    case todoistCredential = "todoist-credential"
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

    /// Settings that kept a secret in plain Defaults before the Keychain store existed.
    private static let legacyDefaultsKeys: [(defaults: Defaults.Key<String>, secure: SecureSecretKey)] = [
        (.spotifySPDCCookie, .spotifySPDCCookie),
        (.geminiApiKey, .geminiAPIKey),
        (.openaiApiKey, .openaiAPIKey),
        (.claudeApiKey, .claudeAPIKey),
        (.groqApiKey, .groqAPIKey),
        (.agentStatusPushoverUserKey, .pushoverUserKey),
        (.agentStatusPushoverAppToken, .pushoverAppToken),
        (.agentStatusWebhookURL, .webhookURL),
    ]

    /// Moves legacy plaintext values from Defaults into the Keychain. It runs at every launch, but
    /// touches the Keychain only for a value still in Defaults (almost never), and then off the
    /// main thread with the dialog off. It used to read all eight items on main, dialogs allowed,
    /// at every launch: an item saved by a differently signed Kannu (Debug and Release share the
    /// service name) could raise a SecurityAgent dialog that held the launch until answered.
    static func migrateFromDefaultsIfNeeded() {
        let pending = legacyDefaultsKeys.compactMap { key -> (Defaults.Key<String>, SecureSecretKey, String)? in
            let legacy = Defaults[key.defaults].trimmingCharacters(in: .whitespacesAndNewlines)
            return legacy.isEmpty ? nil : (key.defaults, key.secure, legacy)
        }
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for (defaultsKey, secureKey, legacy) in pending {
                let existing = read(secureKey, allowInteraction: false)
                let step = LegacySecretMigration.step(
                    existingValue: existing.value,
                    needsApproval: KeychainReader.needsUserApproval(existing.status),
                    itemNotFound: existing.status == errSecItemNotFound
                )
                let clear: Bool
                switch step {
                case .store: clear = set(legacy, for: secureKey)
                case .clearLegacy: clear = true
                case .retryNextLaunch: clear = false
                }
                if clear {
                    DispatchQueue.main.async { Defaults[defaultsKey] = "" }
                }
            }
        }
    }
}
