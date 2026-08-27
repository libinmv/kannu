import Defaults
import Foundation

struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    let root: URL
    let quotaClient: ClaudeQuotaClient

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), quotaClient: ClaudeQuotaClient = ClaudeQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date, interactive: Bool) async throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now

        if FileManager.default.fileExists(atPath: root.path) {
            let files = jsonlFiles(under: root)
            if !files.isEmpty {
                snapshot = JSONLUsageParser.aggregate(files: files, now: now)
            } else {
                snapshot.logsUnavailable = true
            }
        } else {
            snapshot.logsUnavailable = true
        }

        // Read plan details off disk first. This needs no keychain, no network and can't be
        // rate-limited, so the tier badge renders even when the quota call below fails or the
        // user hasn't approved keychain access.
        let localAccount = ClaudeLocalAccountReader.read()
        snapshot.accountTier = localAccount.tier
        snapshot.accountNote = localAccount.note

        // Claude Code usage is covered by a subscription, so per-token pricing estimates are
        // meaningless here — show token counts, never dollars. This describes the billing
        // model itself, so it must be set before any early return below.
        snapshot.billedCostOnly = true

        // Everything above came off disk. The limits below are the only part that needs the
        // network and a keychain approval, so they're opt-in — with this off there is no
        // request, no prompt, and nothing that can be rate-limited.
        guard Defaults[.enableClaudeUsageLimits] else {
            // The one silence that cost a debugging session: with the toggle off the manager
            // logs a clean "refresh ok" and nothing says WHY there are no gauges.
            QuotaDebugLog.log("ClaudeQuota", "limits toggle off — skipping /oauth/usage entirely")
            // With limits off AND no local logs the snapshot is entirely empty — returning it
            // as a success would let the manager's keep-last-good logic get overwritten by
            // nothing. Throw so a populated card is preserved instead.
            if snapshot.logsUnavailable {
                throw UsageError.notConfigured("No Claude Code usage logs found at ~/.claude/projects.")
            }
            return snapshot
        }

        let quota = await quotaClient.fetchLimits(interactive: interactive)
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        // Always surface why quota is missing — hiding it whenever local logs happen to
        // exist left the card showing a bare "quota unavailable" with no way to act on it.
        snapshot.quotaError = quota.errorMessage
        snapshot.quotaAction = quota.action
        snapshot.isAuthFailure = quota.isAuthFailure
        // Only let the API override the local answer when it actually returned one.
        // `billedCostOnly` is set earlier, above the opt-in guard: it describes the billing
        // model itself, so it must hold even when the limits fetch is skipped entirely.
        if let apiTier = quota.accountTier { snapshot.accountTier = apiTier }

        // Even with neither logs nor quota, return the snapshot rather than throwing: the
        // card can then render the reason plus its fix-it button instead of a dead end.
        return snapshot
    }

    private func jsonlFiles(under dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}

enum UsageError: LocalizedError {
    case notFound(String)
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m), .notConfigured(let m): return m
        }
    }
}
