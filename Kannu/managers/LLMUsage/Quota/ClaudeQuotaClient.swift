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

/// A short-lived, memory-only view of Claude Code's own credentials.
///
/// Kannu is strictly a *reader* of this credential — it must never refresh it. Claude Code's
/// refresh tokens are rotating and single-use, so if Kannu spent one, the CLI's copy went
/// stale, its next refresh got rejected, and the whole token family was invalidated — the
/// user found their `claude` login wiped (empty accessToken/refreshToken in the keychain).
/// The CLI rotates tokens on its own schedule and rewrites its keychain item; Kannu just
/// re-reads. Once the user grants "Always Allow", the non-interactive read never prompts,
/// so a durable Kannu-owned copy isn't needed — and keeping one is exactly what made a
/// stale token get used in the first place.
actor ClaudeCredentialStore {
    static let shared = ClaudeCredentialStore()

    /// How long a read is trusted before the CLI's item is consulted again. Short, so a CLI
    /// rotation is picked up on the next poll rather than served stale from memory.
    private static let cacheTTL: TimeInterval = 60

    private var cached: (creds: ClaudeOAuthCredentials, at: Date)?

    private var lookupInFlight: (interactive: Bool, task: Task<ClaudeCredentialLookup, Never>)?

    func get() -> ClaudeOAuthCredentials? {
        guard let cached else { return nil }
        guard Date().timeIntervalSince(cached.at) < Self.cacheTTL else {
            // Drop the expired entry rather than merely ignoring it, so a dead credential
            // can't linger in memory for the process lifetime.
            self.cached = nil
            return nil
        }
        return cached.creds
    }

    /// Runs a credential lookup at most once no matter how many callers arrive together.
    ///
    /// Without this, two overlapping interactive lookups both fell through to the prompting
    /// keychain read and macOS showed the approval dialog twice. Concurrent callers now await
    /// the same in-flight task; an interactive request never downgrades to a non-interactive
    /// in-flight result silently — it waits for that one, then runs its own pass if needed.
    func lookup(
        interactive: Bool,
        perform: @escaping @Sendable (Bool) async -> ClaudeCredentialLookup
    ) async -> ClaudeCredentialLookup {
        if let inFlight = lookupInFlight {
            let piggybacked = await inFlight.task.value
            // A non-interactive caller, or an interactive one whose predecessor could already
            // prompt, is fully served by the shared result.
            if inFlight.interactive || !interactive { return piggybacked }
            // Interactive caller rode a quiet lookup that couldn't prompt — only re-run when
            // prompting is actually what's missing.
            if case .needsKeychainPermission = piggybacked {} else { return piggybacked }
        }
        let task = Task { await perform(interactive) }
        lookupInFlight = (interactive, task)
        let result = await task.value
        // Identity check, not a bare nil. The actor is released across `await task.value`, so a
        // caller that piggybacked on this task can resume first, install its own lookup, and be
        // mid-prompt by the time we get back — clearing unconditionally would erase a live entry
        // and let the next arrival start a second prompting read, stacking two keychain dialogs.
        if lookupInFlight?.task == task { lookupInFlight = nil }
        return result
    }

    func set(_ creds: ClaudeOAuthCredentials) {
        cached = (creds, Date())
        QuotaDebugLog.log("CredStore", "cached in memory (token len \(creds.accessToken.count), expires in \(Self.expiryDelta(creds)))")
    }

    /// Forgets the in-memory copy so the next lookup re-reads Claude Code's keychain item —
    /// e.g. after the server rejects the token, meaning the CLI has probably rotated it.
    func invalidate() {
        cached = nil
        QuotaDebugLog.log("CredStore", "memory cache invalidated")
    }

    private static func expiryDelta(_ creds: ClaudeOAuthCredentials) -> String {
        let mins = (Double(creds.expiresAt) / 1000 - Date().timeIntervalSince1970) / 60
        return String(format: "%.0fm", mins)
    }
}

/// Rate-limit state for the quota endpoint, plus the last result worth showing.
///
/// `ClaudeQuotaClient` is a struct recreated per call, so the cooldown has to live somewhere
/// durable. Keeping the last good result here means a 429 leaves the card showing real numbers
/// instead of replacing them with an error the user can do nothing about.
actor ClaudeQuotaCooldown {
    static let shared = ClaudeQuotaCooldown()

    /// Kept results older than this are dropped rather than served — "last known usage" that
    /// is an hour old is worse than an honest error.
    private static let maxCachedResultAge: TimeInterval = 540

    private var retryAfter: Date?
    private var lastGood: (result: QuotaFetchResult, at: Date)?

    /// Atomically answers "may a request proceed, and if not what should the caller show".
    ///
    /// One call, not two: checking the cooldown and fetching the cached result as separate
    /// awaits left a gap where a concurrent `noteSuccess` could clear the cooldown and install
    /// fresh numbers — which the caller then returned stamped with the rate-limited label.
    func admitOrCached(now: Date = Date()) -> (admitted: Bool, cached: QuotaFetchResult?, remaining: TimeInterval) {
        guard let retryAfter, retryAfter > now else { return (true, nil, 0) }
        let remaining = retryAfter.timeIntervalSince(now)
        guard let lastGood, now.timeIntervalSince(lastGood.at) < Self.maxCachedResultAge else {
            return (false, nil, remaining)
        }
        var result = lastGood.result
        result.errorMessage = "Rate-limited — showing last known usage."
        return (false, result, remaining)
    }

    /// Installs the backoff and returns the cached fallback in one atomic step.
    ///
    /// These were two separate `await`s at the call site, which reopened the very gap
    /// `admitOrCached` was written to close: a concurrent `noteSuccess` landing between them
    /// wipes the backoff we just installed *and* swaps in fresh numbers that then get labelled
    /// "showing last known usage" — stale-looking good data, and an immediate re-429 because
    /// the cooldown is gone. One actor hop, no interleaving.
    func noteRateLimited(retryAfterSeconds: TimeInterval, now: Date = Date()) -> QuotaFetchResult? {
        retryAfter = now.addingTimeInterval(retryAfterSeconds)
        return cachedResult(now: now)
    }

    func noteSuccess(_ result: QuotaFetchResult, now: Date = Date()) {
        retryAfter = nil
        lastGood = (result, now)
    }

    /// Last good result if still fresh, labelled so the card shows its provenance.
    func cachedResult(now: Date = Date()) -> QuotaFetchResult? {
        guard let lastGood, now.timeIntervalSince(lastGood.at) < Self.maxCachedResultAge else { return nil }
        var result = lastGood.result
        result.errorMessage = "Rate-limited — showing last known usage."
        return result
    }
}

struct ClaudeQuotaClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "ClaudeQuota")
    /// Used when the server rate-limits us without a usable `Retry-After` header.
    private static let defaultRateLimitCooldown: TimeInterval = 300
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private static let claudeCodeKeychainService = "Claude Code-credentials"
    /// Used when the installed CLI version can't be read from `~/.claude.json`.
    private static let fallbackCLIVersion = "2.1.223"

    private struct CredentialFile: Decodable, Sendable {
        let claudeAiOauth: ClaudeOAuthCredentials
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
        // Still rate-limited: don't spend another request confirming it. Show the last real
        // figures if we have them, so the card degrades to "slightly stale" rather than "error".
        // A user-initiated attempt goes through regardless — the tap on the fix-it button must
        // be able to reach the keychain approval below, and one manual request is harmless.
        if !interactive {
            let gate = await ClaudeQuotaCooldown.shared.admitOrCached()
            if !gate.admitted {
                if let cached = gate.cached { return cached }
                let minutes = max(1, Int((gate.remaining / 60).rounded(.up)))
                return QuotaFetchResult(errorMessage: "Claude usage limits rate-limited — retrying in ~\(minutes) min.")
            }
        }

        let creds: ClaudeOAuthCredentials
        // Single-flighted: overlapping callers share one lookup instead of racing to the
        // prompting keychain read (two interactive callers used to mean two system dialogs).
        let lookup = await ClaudeCredentialStore.shared.lookup(interactive: interactive) { allowPrompt in
            await self.currentCredentials(interactive: allowPrompt)
        }
        switch lookup {
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
            return QuotaFetchResult(errorMessage: "Claude login found but unreadable — sign in again with `claude`.", isAuthFailure: true)
        case .notSignedIn:
            Self.log.notice("no Claude credentials in ~/.claude/.credentials.json or Keychain")
            return QuotaFetchResult(errorMessage: "Claude Code not signed in — run `claude` in a terminal and log in.", isAuthFailure: true)
        }

        // Kannu never refreshes this token — Claude Code's refresh tokens rotate and are
        // single-use, so spending one here is what used to invalidate the CLI's whole login.
        // If the token is expired we simply wait: the CLI refreshes on its own schedule and
        // rewrites its keychain item, and the next poll re-reads it.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard creds.expiresAt > nowMs else {
            await ClaudeCredentialStore.shared.invalidate()
            QuotaDebugLog.log("ClaudeQuota", "access token expired \((nowMs - creds.expiresAt) / 60000)m ago — waiting for Claude Code to refresh it")
            return QuotaFetchResult(errorMessage: "Waiting for Claude Code to refresh its login — use `claude` once if this persists.")
        }
        let token = creds.accessToken

        // Anthropic rate-limits unknown user agents almost immediately, so the UA must look
        // like the CLI actually installed on this machine — a pinned literal goes stale.
        let cliVersion = ClaudeLocalAccountReader.read().cliVersion ?? Self.fallbackCLIVersion
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")
        QuotaDebugLog.log("ClaudeQuota", "GET oauth/usage (UA claude-code/\(cliVersion), token len \(token.count), expires in \((creds.expiresAt - nowMs) / 60000)m)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("oauth/usage HTTP \(code)")
                if code == 429 {
                    let retryAfter = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Retry-After")
                        .flatMap(TimeInterval.init)
                        ?? Self.defaultRateLimitCooldown
                    let cached = await ClaudeQuotaCooldown.shared.noteRateLimited(retryAfterSeconds: retryAfter)
                    Self.log.notice("oauth/usage rate limited, backing off \(Int(retryAfter))s")
                    if let cached { return cached }
                    let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
                    return QuotaFetchResult(errorMessage: "Claude usage limits rate-limited — retrying in ~\(minutes) min.")
                }
                if code == 401 || code == 403 {
                    // The CLI has probably rotated the token since we read it. Dropping the
                    // memory cache makes the next poll re-read the CLI's keychain item — a
                    // non-interactive read that never prompts once "Always Allow" is granted.
                    //
                    // Deliberately NOT flagged `isAuthFailure`: since Kannu stopped refreshing
                    // tokens, a 401 here is routine CLI rotation, not a sign-out. Marking it
                    // fatal would banish a working provider to the unavailable chip. Genuine
                    // "not signed in" is already flagged at the `.notSignedIn` case above.
                    await ClaudeCredentialStore.shared.invalidate()
                    QuotaDebugLog.log("ClaudeQuota", "HTTP \(code) — token likely rotated by the CLI; will re-read on next poll")
                    return QuotaFetchResult(errorMessage: "Claude login was rotated — retrying with Claude Code's current login.")
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
            let result = QuotaFetchResult(session: sessionLimit, week: weekLimit, accountTier: tier?.capitalized)
            await ClaudeQuotaCooldown.shared.noteSuccess(result)
            return result
        } catch {
            Self.log.error("oauth/usage failed: \(error.localizedDescription, privacy: .public)")
            return QuotaFetchResult(errorMessage: error.localizedDescription)
        }
    }

    /// Ordered fallback chain — each step is tried only if the previous one came up empty:
    /// 1. short-lived memory cache (never prompts; expires so CLI rotations are picked up)
    /// 2. ~/.claude/.credentials.json (never prompts; absent on macOS Claude Code installs)
    /// 3. Claude Code's keychain item without UI (works once "Always Allow" was granted)
    /// 4. Claude Code's keychain item with the system prompt — user-initiated only
    private func currentCredentials(interactive: Bool) async -> ClaudeCredentialLookup {
        if let cached = await ClaudeCredentialStore.shared.get() {
            QuotaDebugLog.log("ClaudeQuota", "credentials from memory cache")
            return .found(cached)
        }

        if let fromFile = Self.credentialsFromFile() {
            await ClaudeCredentialStore.shared.set(fromFile)
            QuotaDebugLog.log("ClaudeQuota", "credentials from ~/.claude/.credentials.json")
            return .found(fromFile)
        }

        let quiet = Self.credentialsFromClaudeKeychain(allowInteraction: false)
        if case .found(let creds) = quiet {
            await ClaudeCredentialStore.shared.set(creds)
            QuotaDebugLog.log("ClaudeQuota", "credentials from CLI keychain (non-interactive)")
            return quiet
        }
        guard case .needsKeychainPermission = quiet else {
            QuotaDebugLog.log("ClaudeQuota", "credential lookup: \(quiet)")
            return quiet
        }
        guard interactive else { return .needsKeychainPermission }

        let prompted = Self.credentialsFromClaudeKeychain(allowInteraction: true)
        if case .found(let creds) = prompted {
            await ClaudeCredentialStore.shared.set(creds) // approve once, never prompt again
            QuotaDebugLog.log("ClaudeQuota", "credentials from CLI keychain (user approved prompt)")
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
        guard let creds = (try? decoder.decode(CredentialFile.self, from: data))?.claudeAiOauth else { return nil }
        // A blanked-out credential (empty tokens, expiresAt 0) is what an invalidated login
        // looks like on disk. Treating it as "found" used to send `Authorization: Bearer `
        // with nothing after it — a guaranteed 401 and, on retry, a 429.
        guard !creds.accessToken.isEmpty else {
            QuotaDebugLog.log("ClaudeQuota", "credential parsed but accessToken is empty — treating as signed out")
            return nil
        }
        return creds
    }
}
