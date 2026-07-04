import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let root: URL
    let quotaClient: CodexQuotaClient

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"), quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("No ~/.codex/sessions — Codex not detected")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UsageError.notFound("No Codex usage logs found")
        }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { throw UsageError.notFound("No Codex usage logs found") }
        var snapshot = JSONLUsageParser.aggregate(files: files, now: now)
        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        return snapshot
    }
}
