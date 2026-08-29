import Defaults
import Foundation

struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
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

        // Rate-limit windows come from Claude itself: it hands rate_limits to the configured
        // statusLine command, which writes claude-usage.json. No credentials, no keychain, no
        // API call — the OAuth/keychain path this used to take could not read the credential
        // format reliably and produced a permanent "credentials unparseable" error.
        await applyRateLimitWindows(to: &snapshot, now: now)
        // Subscription usage isn't billed per-token; show token counts but never
        // pricing-table cost estimates (parity with how Cursor shows billed spend only).
        snapshot.billedCostOnly = true

        // Even with neither logs nor quota, return the snapshot rather than throwing: the
        // card can then render the reason plus its fix-it button instead of a dead end.
        return snapshot
    }

    /// Maps the cached rate-limit windows onto the card's gauges.
    ///
    /// Reads `CursorAgentStatusMonitor`'s cache rather than the file: the monitor owns when usage
    /// is re-read (once per 10 minutes, while an agent is on screen), and a second reader on a
    /// different cadence would defeat that. Staleness rules live in `ClaudeUsageSnapshot` —
    /// percentages vanish once a window is past its reset, and the card falls back to token counts
    /// when nothing usable is cached.
    @MainActor
    private func applyRateLimitWindows(to snapshot: inout UsageSnapshot, now: Date) {
        guard Defaults[.enableClaudeUsageDisplay] else { return }
        guard let usage = CursorAgentStatusMonitor.shared.claudeUsage else { return }

        for window in usage.displayWindows(now: now) {
            let limit = UsageLimit(used: window.percent, limit: 100, resetsAt: window.resetsAt)
            switch window.key {
            case ClaudeUsageSnapshot.fiveHourKey: snapshot.sessionLimit = limit
            case ClaudeUsageSnapshot.sevenDayKey: snapshot.weekLimit = limit
            // A plan may report further weekly windows (per-model, per-surface). Render whatever
            // arrives instead of hardcoding a list that goes stale the day one is added.
            default: snapshot.extraLimits.append(NamedLimit(key: window.key, limit: limit))
            }
        }
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
