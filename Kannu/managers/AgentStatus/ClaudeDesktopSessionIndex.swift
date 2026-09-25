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

/// Claude Desktop's own index of the Claude Code chats its Code tab hosts, read so a click on a
/// session row can land on that exact chat.
///
/// Desktop keeps one JSON per chat under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`,
/// keyed by its own session id (`local_…`). That id equals the CLI session UUID — Kannu's
/// `conversationID`, the transcript file name — only when the chat is born; it diverges after a
/// resume, `/clear` or compaction, which is why `claude://resume?session=<cli uuid>` imported a
/// duplicate for live chats. Desktop's handler has two focus routes for a `local_` id and both
/// create nothing: `claude://code/continue?session=<id>` (roster lookup, but behind a feature
/// gate — on this machine it logged "code entry deep link gated off" and did nothing) and
/// `claude://claude.ai/epitaxy/<id>` (direct in-app navigation to the session route, ungated —
/// verified: `[CCD] LocalSessions.setFocusedSession: sessionId=<id>` in Desktop's main.log, no
/// new `claude` host). Kannu uses the second. Desktop 1.46388.4; ids are validated against its
/// own `^local_[A-Za-z0-9-]{1,64}$`. Record keys observed 2026-09-09; the lineage keys come from
/// the bundle and were absent from every record on that machine.
///
/// Files are 100+ KB (each embeds the chat's MCP catalog) and rewritten on every Desktop turn,
/// so the loader runs on a worker and caches per file by (mtime, size) — docs/REGRESSIONS.md
/// entry 11. Nothing here reads a process environment: the hosted child's carries the same id
/// beside an OAuth token, and that block is never touched.
enum ClaudeDesktopSessionIndex {
    /// `~/.claude/sessions/<pid>.json` `entrypoint` for a session Desktop's Code tab hosts.
    static let desktopEntrypoint = "claude-desktop"
    static let recordFilePrefix = "local_"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    struct Record: Equatable {
        /// Desktop's id, `local_<uuid>`.
        var sessionID: String
        /// The CLI session the chat currently runs as.
        var cliSessionID: String?
        /// CLI sessions this chat ran as before (`priorCliSessionIds`, `unarchivedCliSessionId`,
        /// `preClearCliSessionId`).
        var priorCLISessionIDs: [String]
        var cwd: String?
        var title: String?
        var isArchived: Bool
        var lastActivityAt: Date?
    }

    // MARK: - Pure

    /// Nil unless `sessionId` is a well-formed Desktop id; every other key is optional.
    static func record(from json: [String: Any]) -> Record? {
        guard let sessionID = json["sessionId"] as? String, isValidDesktopSessionID(sessionID) else { return nil }
        var lineage: [String] = []
        if let prior = json["priorCliSessionIds"] as? [String] {
            lineage += prior.filter { !$0.isEmpty }
        }
        for key in ["unarchivedCliSessionId", "preClearCliSessionId"] {
            if let id = json[key] as? String, !id.isEmpty { lineage.append(id) }
        }
        let activityMs = (json["lastActivityAt"] as? NSNumber)?.doubleValue
        return Record(
            sessionID: sessionID,
            cliSessionID: (json["cliSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            priorCLISessionIDs: lineage,
            cwd: json["cwd"] as? String,
            title: json["title"] as? String,
            isArchived: (json["isArchived"] as? Bool) ?? false,
            lastActivityAt: activityMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// Whether a `~/.claude/sessions/<pid>.json` record belongs to a Desktop-hosted session.
    static func isDesktopHosted(sessionFile json: [String: Any]) -> Bool {
        (json["entrypoint"] as? String) == desktopEntrypoint
    }

    /// A direct `cliSessionId` match beats lineage; non-archived beats archived; the newest
    /// activity wins. An archived-only match still resolves: `continue` on it is a safe no-op,
    /// whereas falling back to an importing `resume` on a diverged id creates a duplicate.
    static func desktopSessionID(forCLISession cliSessionID: String, in records: [Record]) -> String? {
        let wanted = cliSessionID.lowercased()
        func rank(_ record: Record) -> (Int, Int, TimeInterval) {
            let direct = record.cliSessionID?.lowercased() == wanted ? 1 : 0
            return (direct, record.isArchived ? 0 : 1, record.lastActivityAt?.timeIntervalSince1970 ?? 0)
        }
        let matches = records.filter { record in
            record.cliSessionID?.lowercased() == wanted
                || record.priorCLISessionIDs.contains { $0.lowercased() == wanted }
        }
        return matches.max { rank($0) < rank($1) }?.sessionID
    }

    /// Every CLI id any record mentions → its Desktop id, through the one resolver above so the
    /// precedence has a single definition. Keys are lowercased.
    static func desktopSessionIDsByCLISessionID(_ records: [Record]) -> [String: String] {
        var cliIDs = Set<String>()
        for record in records {
            if let id = record.cliSessionID { cliIDs.insert(id) }
            cliIDs.formUnion(record.priorCLISessionIDs)
        }
        var map: [String: String] = [:]
        for id in cliIDs {
            if let desktopID = desktopSessionID(forCLISession: id, in: records) {
                map[id.lowercased()] = desktopID
            }
        }
        return map
    }

    /// The attach rule. A live session must say it is Desktop-hosted: a terminal session that
    /// was once imported into Desktop has a record too, and its click must stay on the terminal.
    /// A dead-process session takes whatever the index resolves — Desktop's copy is then the
    /// only place the chat lives.
    static func resolvedDesktopSessionID(
        cliSessionID: String,
        processAlive: Bool,
        sessionFile json: [String: Any],
        idMap: [String: String]
    ) -> String? {
        if processAlive, !isDesktopHosted(sessionFile: json) { return nil }
        return idMap[cliSessionID.lowercased()]
    }

    /// Desktop's own validator: `^local_[A-Za-z0-9-]{1,64}$`. `last` (which its `continue`
    /// route also accepts) is deliberately rejected — it would focus whatever chat was last
    /// open, today's behaviour disguised as success.
    static func isValidDesktopSessionID(_ id: String) -> Bool {
        guard id.hasPrefix(recordFilePrefix) else { return false }
        let body = id.dropFirst(recordFilePrefix.count)
        guard !body.isEmpty, body.count <= 64 else { return false }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// `claude://claude.ai/epitaxy/<local id>` — Desktop's in-app route for a Code-tab chat,
    /// reached through the `claude://claude.ai/…` navigation branch of its URL handler. The id
    /// is validated first, so the path can carry nothing but Desktop's own id characters.
    static func focusDeepLink(desktopSessionID: String) -> URL? {
        guard isValidDesktopSessionID(desktopSessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "claude.ai"
        components.path = "/epitaxy/" + desktopSessionID
        return components.url
    }

    /// `<root>/<account>/<org>/local_*.json`, regular files only — `deleted_<uuid>/` tombstones
    /// and any `local_<uuid>/` sidecar directories are skipped. Sorted for determinism.
    static func recordFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        func directories(in url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        var files: [URL] = []
        for account in directories(in: root) {
            for org in directories(in: account) {
                let entries = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
                for entry in entries
                where entry.lastPathComponent.hasPrefix(recordFilePrefix) && entry.pathExtension == "json"
                    && (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(entry)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Loader (worker-side)

    /// Reads the index, re-parsing only files whose (mtime, size) changed. An instance, not a
    /// static cache: it is touched from one worker at a time and built fresh in tests.
    final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: (mtime: Date, size: Int, record: Record?)] = [:]
        private var parses = 0

        /// How many files were parsed so far — the cache's test hook.
        var parseCount: Int {
            lock.lock(); defer { lock.unlock() }
            return parses
        }

        func records(root: URL) -> [Record] {
            let files = ClaudeDesktopSessionIndex.recordFiles(root: root)
            lock.lock(); defer { lock.unlock() }
            var seen = Set<String>()
            var out: [Record] = []
            for url in files {
                seen.insert(url.path)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                let size = values?.fileSize ?? -1
                if let cached = cache[url.path], cached.mtime == mtime, cached.size == size {
                    if let record = cached.record { out.append(record) }
                    continue
                }
                parses += 1
                let record = (try? Data(contentsOf: url))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { ClaudeDesktopSessionIndex.record(from: $0) }
                cache[url.path] = (mtime, size, record)
                if let record { out.append(record) }
            }
            cache = cache.filter { seen.contains($0.key) }
            return out
        }
    }
}
