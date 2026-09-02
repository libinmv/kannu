/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// Antigravity does not expose a public token/cost usage API.
/// This provider reads the hook-written status files from
/// `~/.kannu/agent-status/antigravity-*.json` and surfaces
/// session count and last-active timestamp information.
struct AntigravityUsageProvider: UsageProvider {
    let id: ProviderID = .antigravity
    let statusDir: URL
    /// Reads local JSON files — no network cost, refresh every open.
    var isLocalFileProvider: Bool { true }

    init(statusDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kannu/agent-status")) {
        self.statusDir = statusDir
    }

    func fetchSnapshot(now: Date, interactive: Bool = false) async throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now
        snapshot.logsUnavailable = true   // no token logs for Antigravity
        snapshot.billedCostOnly = true    // hide cost columns entirely

        let files = antigravityStatusFiles()
        if files.isEmpty {
            throw UsageError.notConfigured("No Antigravity sessions found. Start a chat in Antigravity IDE to see session info here.")
        }

        var latestTs: Int64 = 0
        var sessionCount = 0
        var lastState = ""

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let ts = (json["ts"] as? NSNumber)?.int64Value ?? 0
            let state = (json["state"] as? String) ?? ""
            // Skip simulation / test sessions
            let convID = file.deletingPathExtension().lastPathComponent
            guard !convID.lowercased().contains("default"),
                  !convID.lowercased().contains("kannu-test"),
                  !convID.lowercased().hasPrefix("test-")
            else { continue }
            // Only count sessions active within 24 hours
            let ageSeconds = (Int64(now.timeIntervalSince1970 * 1000) - ts) / 1000
            guard ageSeconds < 86_400 else { continue }

            sessionCount += 1
            if ts > latestTs {
                latestTs = ts
                lastState = state
            }
        }

        if sessionCount == 0 {
            throw UsageError.notConfigured("No recent Antigravity sessions in the last 24 hours.")
        }

        // Surface session info via quotaError field (repurposed as status message here)
        let lastDate = Date(timeIntervalSince1970: TimeInterval(latestTs) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relTime = formatter.localizedString(for: lastDate, relativeTo: now)
        let stateLabel = lastState.isEmpty ? "" : " · \(lastState.replacingOccurrences(of: "_", with: " "))"
        snapshot.quotaError = "\(sessionCount) session\(sessionCount == 1 ? "" : "s") · last active \(relTime)\(stateLabel)"

        return snapshot
    }

    private func antigravityStatusFiles() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: statusDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return items.filter {
            $0.pathExtension == "json" &&
            $0.lastPathComponent.hasPrefix("antigravity-")
        }
    }
}
