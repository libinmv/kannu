import Foundation
import os

struct ClaudeOAuthCredentials: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
    var subscriptionType: String? = nil
}

/// Where a credential lookup ended up. Each failure is distinct so the UI can offer the
/// matching fix instead of a generic "not signed in".
enum ClaudeCredentialLookup {
    case found(ClaudeOAuthCredentials)
    /// Claude Code's keychain item exists, but macOS wants the user to approve Kannu reading it.
    case needsKeychainPermission
    /// A credential source was readable but its payload didn't parse.
    case unreadable
    case notSignedIn
}

/// Caches Claude's OAuth credentials in memory and in a *Kannu-owned* keychain item.
///
/// Claude Code stores its tokens in a keychain item owned by the CLI, so every read from
/// Kannu triggers the cross-app "wants to use your confidential information" dialog. Once
/// the user approves that read a single time, the copy kept here means later launches and
/// background refreshes never prompt again.
actor ClaudeCredentialStore {
    static let shared = ClaudeCredentialStore()

    private static let service = "com.kannu.app.llm-credentials"
    private static let account = "claude-oauth"
    private static let coder = (encoder: JSONEncoder(), decoder: JSONDecoder()) // camelCase, matching Claude's own payload

    private var cached: ClaudeOAuthCredentials?
    private var readOwnCopy = false

    func get() -> ClaudeOAuthCredentials? {
        if cached == nil, !readOwnCopy {
            readOwnCopy = true
            cached = Self.loadOwnCopy()
        }
        return cached
    }

    func set(_ creds: ClaudeOAuthCredentials) {
        cached = creds
        readOwnCopy = true
        guard let data = try? Self.coder.encoder.encode(creds), let json = String(data: data, encoding: .utf8) else { return }
        KeychainReader.setGenericPassword(json, service: Self.service, account: Self.account)
    }

    /// Drops our copy so the next lookup falls back to Claude Code's own credentials.
    /// Used when the server rejects the token we cached (revoked, rotated by the CLI, signed out).
    func clear() {
        cached = nil
        readOwnCopy = true
        KeychainReader.deleteGenericPassword(service: Self.service, account: Self.account)
    }

    private static func loadOwnCopy() -> ClaudeOAuthCredentials? {
        guard let json = KeychainReader.genericPassword(service: service, account: account) else { return nil }
        return try? coder.decoder.decode(ClaudeOAuthCredentials.self, from: Data(json.utf8))
    }
}

struct ClaudeQuotaClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "ClaudeQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshScope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let refreshSkewMs: Int64 = 5 * 60 * 1000
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    private struct CredentialFile: Decodable, Sendable {
        let claudeAiOauth: ClaudeOAuthCredentials
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    private enum ResetsAt: Decodable {
        case iso(String)
        case epochMs(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .iso(s) }
            else { self = .epochMs(try c.decode(Double.self)) }
        }
        var date: Date? {
            switch self {
            case .iso(let s): return Self.parseISO(s)
            case .epochMs(let ms): return Date(timeIntervalSince1970: ms / 1000)
            }
        }
        // ISO8601DateFormatter is all-or-nothing about fractional seconds, so try both shapes.
        private static func parseISO(_ s: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ISO8601DateFormatter().date(from: s) ?? withFraction.date(from: s)
        }
    }

    private struct Window: Decodable {
        let utilization: Double
        let resetsAt: ResetsAt
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let subscriptionType: String? // only sent by some accounts; used when the stored credentials omit the tier
    }

    /// `interactive` gates the one step that can show a system dialog: reading Claude Code's
    /// own keychain item. Background refreshes pass `false` and degrade to an actionable
    /// message; the user pressing "Allow keychain access" passes `true`.
    func fetchLimits(interactive: Bool = false) async -> QuotaFetchResult {
        let creds: ClaudeOAuthCredentials
        switch await currentCredentials(interactive: interactive) {
        case .found(let found):
            creds = found
        case .needsKeychainPermission:
            Self.log.notice("Claude keychain item needs user approval")
            return QuotaFetchResult(
                errorMessage: "Kannu needs your approval to read Claude Code's keychain login.",
                action: .grantClaudeKeychainAccess
            )
        case .unreadable:
            Self.log.error("Claude credentials found but unparseable")
            return QuotaFetchResult(errorMessage: "Claude login found but unreadable — sign in again with `claude`.")
        case .notSignedIn:
            Self.log.notice("no Claude credentials in ~/.claude/.credentials.json or Keychain")
            return QuotaFetchResult(errorMessage: "Claude Code not signed in — run `claude` in a terminal and log in.")
        }

        guard let token = await validAccessToken(creds) else {
            Self.log.error("could not obtain valid Claude access token")
            return QuotaFetchResult(errorMessage: "Claude token refresh failed — sign in again with `claude`.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("oauth/usage HTTP \(code)")
                if code == 401 || code == 403 {
                    // Our cached copy is stale (revoked, or the CLI rotated its tokens);
                    // drop it so the next refresh re-reads Claude Code's own credentials.
                    await ClaudeCredentialStore.shared.clear()
                    return QuotaFetchResult(errorMessage: "Claude login expired — it will retry with Claude Code's current login.")
                }
                return QuotaFetchResult(errorMessage: "Claude quota API HTTP \(code)")
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            let sessionLimit = decoded.fiveHour.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            let weekLimit = decoded.sevenDay.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            if sessionLimit == nil && weekLimit == nil {
                return QuotaFetchResult(errorMessage: "Claude quota response missing usage windows")
            }
            let tier = creds.subscriptionType ?? decoded.subscriptionType
            return QuotaFetchResult(session: sessionLimit, week: weekLimit, accountTier: tier?.capitalized)
        } catch {
            Self.log.error("oauth/usage failed: \(error.localizedDescription, privacy: .public)")
            return QuotaFetchResult(errorMessage: error.localizedDescription)
        }
    }

    /// Ordered fallback chain — each step is tried only if the previous one came up empty:
    /// 1. memory / Kannu's own keychain copy (never prompts)
    /// 2. ~/.claude/.credentials.json (never prompts; absent on macOS Claude Code installs)
    /// 3. Claude Code's keychain item without UI (works once "Always Allow" was granted)
    /// 4. Claude Code's keychain item with the system prompt — user-initiated only
    private func currentCredentials(interactive: Bool) async -> ClaudeCredentialLookup {
        if let cached = await ClaudeCredentialStore.shared.get() { return .found(cached) }

        if let fromFile = Self.credentialsFromFile() {
            await ClaudeCredentialStore.shared.set(fromFile)
            return .found(fromFile)
        }

        let quiet = Self.credentialsFromClaudeKeychain(allowInteraction: false)
        if case .found(let creds) = quiet {
            await ClaudeCredentialStore.shared.set(creds)
            return quiet
        }
        guard case .needsKeychainPermission = quiet else { return quiet }
        guard interactive else { return .needsKeychainPermission }

        let prompted = Self.credentialsFromClaudeKeychain(allowInteraction: true)
        if case .found(let creds) = prompted {
            await ClaudeCredentialStore.shared.set(creds) // approve once, never prompt again
        }
        return prompted
    }

    private static func credentialsFromFile() -> ClaudeOAuthCredentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parse(data)
    }

    private static func credentialsFromClaudeKeychain(allowInteraction: Bool) -> ClaudeCredentialLookup {
        let result = KeychainReader.read(service: claudeCodeKeychainService, allowInteraction: allowInteraction)
        guard let json = result.value else {
            return KeychainReader.needsUserApproval(result.status) ? .needsKeychainPermission : .notSignedIn
        }
        guard let creds = parse(Data(json.utf8)) else { return .unreadable }
        return .found(creds)
    }

    private static func parse(_ data: Data) -> ClaudeOAuthCredentials? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(CredentialFile.self, from: data))?.claudeAiOauth
    }

    private func validAccessToken(_ creds: ClaudeOAuthCredentials) async -> String? {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard creds.expiresAt - nowMs <= Self.refreshSkewMs else { return creds.accessToken }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
            "scope": Self.refreshScope
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return creds.accessToken // network hiccup: try the existing token rather than failing outright
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                // Refresh token is dead — most likely our copy went stale after the CLI rotated its own.
                await ClaudeCredentialStore.shared.clear()
            }
            Self.log.error("oauth token refresh HTTP \(http.statusCode)")
            return creds.accessToken
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let refreshed = try? decoder.decode(RefreshResponse.self, from: data) else { return creds.accessToken }
        let expiresAt = nowMs + Int64(refreshed.expiresIn) * 1000
        let updated = ClaudeOAuthCredentials(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken, expiresAt: expiresAt, subscriptionType: creds.subscriptionType)
        await ClaudeCredentialStore.shared.set(updated)
        return refreshed.accessToken
    }
}
