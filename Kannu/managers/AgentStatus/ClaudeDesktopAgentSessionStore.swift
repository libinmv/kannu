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
 *
 */

import Foundation

/// Passive session source for Claude Desktop's local agent mode (shipped as "Cowork").
///
/// The app writes one `audit.jsonl` per session, in the Claude Code SDK stream shape:
/// `system:init` (model, cwd), `user` / `assistant` messages,
/// `result` when a turn finishes, and `rate_limit_event` when the account is throttled.
/// Interactive sessions live at `<user>/<org>/local_<uuid>/audit.jsonl`; dispatch sessions
/// (delegated background agents) one level deeper at `<user>/<org>/agent/local_ditto_<uuid>/`.
///
/// There is no hook API and no process to check, so this is tail-of-file inference like the
/// Claude Code passive path: the newest conversational record decides the raw state and the
/// file's age decides how it is displayed. It never claims yellow — nothing in the log says
/// the app is asking the user something — but it can say "throttled".
enum ClaudeDesktopAgentSessionStore {
    static let providerKey = "claudedesktop"
    static let sessionDirectoryPrefix = "local_"
    static let dispatchDirectoryPrefix = "local_ditto_"
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
    }

    struct Parsed: Equatable {
        var model: String?
        var title: String?
        var cwd: String?
        /// `executing`, `thinking`, `stopped`, `quota_exceeded`, or `idle` when the log holds no
        /// conversational record yet.
        var rawState: String = "idle"
        var recordTimestamp: Date?
        /// Failed tool results and error results since the last user prompt. Diagnostic only.
        var toolErrorCount: Int = 0
        /// The newest `result` record failed: the run's verdict.
        var runError: RunError? = nil
    }

    // MARK: - Parsing (pure)

    /// `head` is the first few KB (holds `system:init`); `tail` the last few KB (holds the
    /// newest records). Either may be nil for an unreadable file.
    static func parse(head: String?, tail: String?) -> Parsed {
        var parsed = Parsed()

        for line in (head ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = jsonObject(line) else { continue }
            let type = json["type"] as? String
            if type == "system", (json["subtype"] as? String) == "init" {
                parsed.model = json["model"] as? String
                parsed.cwd = json["cwd"] as? String
            }
            if parsed.title == nil, let title = json["title"] as? String,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                parsed.title = title
            }
        }

        var decided = false
        var countingErrors = true
        for line in (tail ?? "").split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let json = jsonObject(line), let type = json["type"] as? String else { continue }
            switch type {
            case "rate_limit_event":
                let info = json["rate_limit_info"] as? [String: Any]
                let status = info?["status"] as? String
                if !decided, status == "rejected" {
                    parsed.rawState = "quota_exceeded"
                    parsed.recordTimestamp = AgentSessionLogParser.recordTimestamp(from: json)
                    decided = true
                }
            case "result":
                if countingErrors, (json["is_error"] as? Bool) == true {
                    parsed.toolErrorCount += 1
                }
                if !decided {
                    parsed.rawState = "stopped"
                    parsed.recordTimestamp = AgentSessionLogParser.recordTimestamp(from: json)
                    // The newest record is this run's verdict. `terminal_reason` is deliberately
                    // not read: a user cancel is not a failure.
                    let subtype = json["subtype"] as? String ?? ""
                    if (json["is_error"] as? Bool) == true || subtype.hasPrefix("error") {
                        parsed.runError = ((json["api_error_status"] as? NSNumber)?.intValue)
                            .map { RunError.apiError(status: $0) } ?? .failed
                    }
                    decided = true
                }
            case "assistant":
                let message = json["message"] as? [String: Any]
                let content = message?["content"] as? [[String: Any]] ?? []
                if !decided {
                    if content.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                        parsed.rawState = "executing"
                    } else {
                        let stopReason = message?["stop_reason"] as? String
                        parsed.rawState = (stopReason == nil || stopReason == "tool_use" || stopReason == "pause_turn")
                            ? "thinking" : "stopped"
                    }
                    parsed.recordTimestamp = AgentSessionLogParser.recordTimestamp(from: json)
                    decided = true
                }
            case "user":
                let message = json["message"] as? [String: Any]
                let blocks = (message?["content"] as? [[String: Any]]) ?? []
                let toolResults = blocks.filter { ($0["type"] as? String) == "tool_result" }
                if countingErrors {
                    parsed.toolErrorCount += toolResults.filter { ($0["is_error"] as? Bool) == true }.count
                    if toolResults.isEmpty {
                        // A plain prompt: the turn boundary for the error count.
                        countingErrors = false
                    }
                }
                if !decided {
                    parsed.rawState = "thinking"
                    parsed.recordTimestamp = AgentSessionLogParser.recordTimestamp(from: json)
                    decided = true
                }
            default:
                continue
            }
            if decided, !countingErrors { break }
        }
        return parsed
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Directory layout

    /// `(session id, is dispatch)` for an `audit.jsonl` path, or nil when the parent directory
    /// is not a session directory.
    static func sessionIdentity(forAuditLog url: URL) -> (id: String, isDispatch: Bool)? {
        let directory = url.deletingLastPathComponent().lastPathComponent
        if directory.hasPrefix(dispatchDirectoryPrefix) {
            let id = String(directory.dropFirst(dispatchDirectoryPrefix.count))
            return id.isEmpty ? nil : (id, true)
        }
        if directory.hasPrefix(sessionDirectoryPrefix) {
            let id = String(directory.dropFirst(sessionDirectoryPrefix.count))
            return id.isEmpty ? nil : (id, false)
        }
        return nil
    }

    /// Every `audit.jsonl` modified inside the window. The tree is shallow (user/org/session)
    /// and small, so a bounded enumeration is cheap.
    static func listRecentAuditLogs(root: URL, maxAgeMinutes: Int, now: Date = Date()) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeMinutes * 60))
        var results: [(URL, Date)] = []
        for case let url as URL in enumerator {
            if enumerator.level > 6 { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "audit.jsonl",
                  sessionIdentity(forAuditLog: url) != nil,
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime >= cutoff else { continue }
            results.append((url, mtime))
        }
        return results.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
    }

    // MARK: - Sessions

    // Main-thread-only state, for the same reason AgentSessionLogParser's caches are: this file
    // compiles into the logic-only test target (whose synchronous tests could not call isolated
    // statics), while every production caller is the @MainActor monitor. Keep it that way, or add
    // isolation here and migrate the tests, before this parsing moves off-main.
    private static var parseCache: [String: (mtime: Date, size: Int, parsed: Parsed)] = [:]
    private static let parseCacheCap = 48

    /// `parse(head:tail:)` for a file, remembered against `(mtime, size)`.
    ///
    /// `sessions(...)` runs on the main actor from every full rescan, and an appending session
    /// drives FSEvents on this root as well, so re-reading 48 KB per file per pass would put real
    /// filesystem I/O in front of the UI — the reason the tail-state and title readers next door
    /// are cached the same way. Nothing in `Parsed` depends on the clock (the age ladder is
    /// applied by the caller, from the file's mtime), so a cache hit is exact rather than stale.
    private static func cachedParse(at url: URL, mtime: Date?, size: Int?) -> Parsed {
        if let mtime, let size, let cached = parseCache[url.path],
           cached.mtime == mtime, cached.size == size {
            return cached.parsed
        }
        let parsed = parse(
            head: AgentSessionLogParser.readLeadingLines(at: url),
            tail: AgentSessionLogParser.readTrailingLines(at: url)
        )
        if let mtime, let size {
            if parseCache.count > parseCacheCap { parseCache.removeAll() }
            parseCache[url.path] = (mtime, size, parsed)
        }
        return parsed
    }

    static func sessions(
        root: URL = defaultRoot,
        staleMinutes: Int,
        collapseSeconds: Int,
        inactiveSeconds: Int,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let collapseMs = Int64(collapseSeconds) * 1_000
        let inactiveMs = Int64(inactiveSeconds) * 1_000

        return listRecentAuditLogs(root: root, maxAgeMinutes: staleMinutes, now: now).compactMap { url in
            guard let identity = sessionIdentity(forAuditLog: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? now
            let parsed = cachedParse(at: url, mtime: values?.contentModificationDate, size: values?.fileSize)
            // The file's age, not the record's: SDK stream records rarely carry timestamps,
            // and a quiet "thinking" must age out through the same ladder the hooks use.
            let tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
            let resolved = AgentTrafficLightMapper.resolveHookState(
                rawState: parsed.rawState,
                ageMs: nowMs - tsMs,
                collapseMs: collapseMs,
                inactiveMs: inactiveMs
            )
            let projectName = parsed.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            var session = AgentSessionStatus(
                id: "\(providerKey)-\(identity.id)",
                provider: providerKey,
                conversationID: identity.id,
                chatName: parsed.title ?? (identity.isDispatch ? String(localized: "Dispatch agent") : nil),
                projectName: projectName,
                rawState: parsed.rawState,
                displayState: resolved.state,
                updatedAt: mtime,
                isVisible: resolved.visible,
                executionStartedAt: nil,
                cwd: parsed.cwd,
                hostPID: nil
            )
            session.toolErrorCount = parsed.toolErrorCount
            session.runError = parsed.runError
            return session
        }
    }
}
