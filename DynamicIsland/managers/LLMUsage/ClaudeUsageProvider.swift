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
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("No ~/.claude/projects — Claude Code not detected")
        }
        let files = jsonlFiles(under: root)
        guard !files.isEmpty else { throw UsageError.notFound("No Claude usage logs found") }
        var snapshot = JSONLUsageParser.aggregate(files: files, now: now)
        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
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
