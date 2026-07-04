import Foundation

actor ClaudeCredentialStore {
    static let shared = ClaudeCredentialStore()
    private var cached: ClaudeQuotaClient.CredentialFile.OAuth?

    fileprivate func get() -> ClaudeQuotaClient.CredentialFile.OAuth? { cached }
    fileprivate func set(_ creds: ClaudeQuotaClient.CredentialFile.OAuth) { cached = creds }
}

struct ClaudeQuotaClient {
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshScope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let refreshSkewMs: Int64 = 5 * 60 * 1000

    fileprivate struct CredentialFile: Decodable, Sendable {
        struct OAuth: Decodable, Sendable {
            let accessToken: String
            let refreshToken: String
            let expiresAt: Int64
        }
        let claudeAiOauth: OAuth
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
            case .iso(let s): return ISO8601DateFormatter().date(from: s)
            case .epochMs(let ms): return Date(timeIntervalSince1970: ms / 1000)
            }
        }
    }

    private struct Window: Decodable {
        let utilization: Double
        let resetsAt: ResetsAt
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
    }

    func fetchLimits() async -> (session: UsageLimit?, week: UsageLimit?) {
        guard let creds = await currentCredentials() else { return (nil, nil) }
        guard let token = await validAccessToken(creds) else { return (nil, nil) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return (nil, nil) }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            let sessionLimit = decoded.fiveHour.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            let weekLimit = decoded.sevenDay.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            return (sessionLimit, weekLimit)
        } catch {
            return (nil, nil)
        }
    }

    private func currentCredentials() async -> CredentialFile.OAuth? {
        if let cached = await ClaudeCredentialStore.shared.get() { return cached }
        guard let loaded = Self.loadCredentialsFromSource() else { return nil }
        await ClaudeCredentialStore.shared.set(loaded)
        return loaded
    }

    // File first never prompts; Keychain only as fallback.
    private static func loadCredentialsFromSource() -> CredentialFile.OAuth? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONDecoder().decode(CredentialFile.self, from: data) {
            return parsed.claudeAiOauth
        }
        guard let json = KeychainReader.genericPassword(service: "Claude Code-credentials"),
              let parsed = try? JSONDecoder().decode(CredentialFile.self, from: Data(json.utf8)) else { return nil }
        return parsed.claudeAiOauth
    }

    private func validAccessToken(_ creds: CredentialFile.OAuth) async -> String? {
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
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return creds.accessToken
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let refreshed = try? decoder.decode(RefreshResponse.self, from: data) else { return creds.accessToken }
        let expiresAt = nowMs + Int64(refreshed.expiresIn) * 1000
        let updated = CredentialFile.OAuth(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken, expiresAt: expiresAt)
        await ClaudeCredentialStore.shared.set(updated)
        return refreshed.accessToken
    }
}
