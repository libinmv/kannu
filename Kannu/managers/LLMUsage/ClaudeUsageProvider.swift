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

        let quota = await quotaClient.fetchLimits(interactive: interactive)
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        // Always surface why quota is missing — hiding it whenever local logs happen to
        // exist left the card showing a bare "quota unavailable" with no way to act on it.
        snapshot.quotaError = quota.errorMessage
        snapshot.quotaAction = quota.action
        snapshot.accountTier = quota.accountTier
        snapshot.isAuthFailure = quota.isAuthFailure
        // Subscription usage isn't billed per-token; show token counts but never
        // pricing-table cost estimates (parity with how Cursor shows billed spend only).
        snapshot.billedCostOnly = true

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
