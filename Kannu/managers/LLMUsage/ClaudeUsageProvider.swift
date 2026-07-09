import Foundation

struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    let root: URL
    let quotaClient: ClaudeQuotaClient

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), quotaClient: ClaudeQuotaClient = ClaudeQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
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

        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        snapshot.quotaError = quota.errorMessage

        if snapshot.logsUnavailable && !quota.hasLimits {
            throw UsageError.notConfigured("Sign in to Claude Code locally (~/.claude/.credentials.json) to show quota.")
        }

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
