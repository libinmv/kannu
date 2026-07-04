import Foundation
import os

// Codex/ChatGPT rate-limit usage from chatgpt.com/backend-api/wham/usage; request+response shape per OpenUsage.
struct CodexQuotaClient {
    private static let log = os.Logger(subsystem: "com.atoll.DynamicIsland", category: "CodexQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?
        }
        let tokens: Tokens
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }

    private struct RateLimit: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?
    }

    private struct UsageResponse: Decodable {
        let rateLimit: RateLimit?
    }

    // Never throws: any credential/network/parse failure yields (nil, nil).
    func fetchLimits() async -> (session: UsageLimit?, week: UsageLimit?) {
        guard let creds = loadCredentials() else {
            Self.log.notice("no credentials: auth.json/Keychain missing or unparseable")
            return (nil, nil)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Atoll", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("wham/usage HTTP \(code) — \(code == 401 || code == 403 ? "auth/credential" : "request") failure")
                return (nil, nil)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let now = Date()
            if let decoded = try? decoder.decode(UsageResponse.self, from: data) {
                let sessionLimit = decoded.rateLimit?.primaryWindow.map { limit(from: $0, now: now) }
                let weekLimit = decoded.rateLimit?.secondaryWindow.map { limit(from: $0, now: now) }
                if sessionLimit != nil || weekLimit != nil { return (sessionLimit, weekLimit) }
            }
            let sessionLimit = headerFallback(http, key: "x-codex-primary-used-percent")
            let weekLimit = headerFallback(http, key: "x-codex-secondary-used-percent")
            if sessionLimit == nil && weekLimit == nil {
                Self.log.error("wham/usage 200 but no usage found — response shape may have changed (\(data.count) bytes)")
            }
            return (sessionLimit, weekLimit)
        } catch {
            Self.log.error("wham/usage request errored: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }

    private func limit(from window: RateLimitWindow, now: Date) -> UsageLimit {
        let resets = window.resetAt.map { Date(timeIntervalSince1970: $0) } ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
        return UsageLimit(used: window.usedPercent, limit: 100, resetsAt: resets)
    }

    private func headerFallback(_ http: HTTPURLResponse, key: String) -> UsageLimit? {
        guard let raw = http.value(forHTTPHeaderField: key), let percent = Double(raw) else { return nil }
        return UsageLimit(used: percent, limit: 100)
    }

    // auth.json ($CODEX_HOME, ~/.codex, ~/.config/codex), then Keychain "Codex Auth" holding the same JSON payload.
    private func loadCredentials() -> (accessToken: String, accountId: String?)? {
        for path in authPaths() {
            if let data = try? Data(contentsOf: path), let creds = parseAuth(data) { return creds }
        }
        guard let value = KeychainReader.genericPassword(service: "Codex Auth"),
              let creds = parseAuth(Data(value.utf8)) else { return nil }
        return creds
    }

    private func authPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return [URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")]
        }
        return [
            home.appendingPathComponent(".codex/auth.json"),
            home.appendingPathComponent(".config/codex/auth.json"),
        ]
    }

    private func parseAuth(_ data: Data) -> (accessToken: String, accountId: String?)? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(AuthFile.self, from: data) else { return nil }
        return (parsed.tokens.accessToken, parsed.tokens.accountId)
    }
}
