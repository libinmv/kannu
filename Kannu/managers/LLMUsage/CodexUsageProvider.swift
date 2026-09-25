import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let root: URL
    let quotaClient: CodexQuotaClient

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"), quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date, interactive: Bool) async throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now

        if FileManager.default.fileExists(atPath: root.path),
           let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            if !files.isEmpty {
                // Same rule as the Claude provider, from the same constant: skip files too old to
                // contribute, but decide `logsUnavailable` from the unfiltered listing.
                snapshot = JSONLUsageParser.aggregate(
                    files: UsageWindows.recentlyModified(files, now: now),
                    now: now
                )
            } else {
                snapshot.logsUnavailable = true
            }
        } else {
            snapshot.logsUnavailable = true
        }

        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        snapshot.quotaError = quota.errorMessage
        snapshot.accountTier = quota.accountTier
        snapshot.isAuthFailure = quota.isAuthFailure

        if snapshot.logsUnavailable && !quota.hasLimits {
            throw UsageError.notConfigured("Sign in to Codex locally (~/.codex/auth.json) to show quota.")
        }

        return snapshot
    }
}
