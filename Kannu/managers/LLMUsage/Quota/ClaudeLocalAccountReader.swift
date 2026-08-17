import Foundation

/// Plan and account facts read straight off disk.
struct ClaudeLocalAccount: Equatable {
    /// Display label for the plan, e.g. "Pro" or "Max".
    var tier: String?
    /// A short, actionable note about account state — currently only "out of extra credits".
    var note: String?
    /// The Claude Code CLI version last seen on this machine (`lastOnboardingVersion`), used to
    /// build the quota request's User-Agent. Anthropic rate-limits unknown agents aggressively,
    /// so tracking the real installed version beats pinning a literal that goes stale.
    var cliVersion: String?
}

/// Reads Claude's account details from `~/.claude.json`.
///
/// This is Claude's equivalent of the plain file Cursor keeps its token in: no keychain, no
/// network, no rate limit. The quota API is only needed for live 5h/7d utilization — plan tier
/// and credit state have been sitting in this file unread, behind a permission prompt they never
/// required. Reading it here means the usage card still says something useful when the API is
/// rate-limiting us or the user hasn't approved keychain access.
enum ClaudeLocalAccountReader {
    private static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    // The file is small but reparsing it on every refresh is pointless; mtime is enough to
    // know when it actually changed.
    private static var cached: (modified: Date, account: ClaudeLocalAccount)?
    private static let lock = NSLock()

    static func read() -> ClaudeLocalAccount {
        let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        lock.lock()
        if let cached, cached.modified == modified {
            defer { lock.unlock() }
            return cached.account
        }
        lock.unlock()

        let account = parse()

        lock.lock()
        cached = (modified, account)
        lock.unlock()
        return account
    }

    private static func parse() -> ClaudeLocalAccount {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeLocalAccount()
        }

        let oauth = json["oauthAccount"] as? [String: Any]
        // seatTier and userRateLimitTier are populated on team and enterprise seats and are more
        // specific than organizationType, so they win when present. On a personal plan both are
        // null and organizationType carries the answer ("claude_pro").
        let rawTier = [
            oauth?["seatTier"] as? String,
            oauth?["userRateLimitTier"] as? String,
            oauth?["organizationType"] as? String
        ].compactMap { $0 }.first { !$0.isEmpty }

        return ClaudeLocalAccount(
            tier: rawTier.map(tierLabel),
            note: creditNote(json: json, oauth: oauth),
            cliVersion: (json["lastOnboardingVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func tierLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude_free", "free": return "Free"
        case "claude_pro", "pro": return "Pro"
        case "claude_max", "max": return "Max"
        case "claude_team", "team": return "Team"
        case "claude_enterprise", "enterprise": return "Enterprise"
        default:
            // Unknown or future plan: strip the vendor prefix and title-case whatever is left,
            // so a new tier shows up readable rather than as a raw identifier.
            let trimmed = raw.hasPrefix("claude_") ? String(raw.dropFirst("claude_".count)) : raw
            return trimmed
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func creditNote(json: [String: Any], oauth: [String: Any]?) -> String? {
        guard oauth?["hasExtraUsageEnabled"] as? Bool == true else { return nil }
        guard let reason = json["cachedExtraUsageDisabledReason"] as? String, !reason.isEmpty else { return nil }
        switch reason {
        case "out_of_credits": return "Out of extra credits"
        default: return nil
        }
    }
}
