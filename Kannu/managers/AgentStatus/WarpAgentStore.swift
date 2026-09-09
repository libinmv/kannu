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
import SQLite3

/// Passive session source for Warp's agent mode.
///
/// Warp has no hook API. It keeps every agent exchange in `warp.sqlite`: `ai_queries` holds one
/// row per exchange with `output_status` (`Pending`, `Completed`, `Cancelled`, `Failed`), a
/// start timestamp and the working directory. That is enough for green/red and for a per-turn
/// error, but not for yellow — an approval prompt is not distinguishable in these tables, so
/// this source never claims it.
///
/// Read-only, WAL honoured: the main file lags the write-ahead log by hundreds of MB on a busy
/// install, so opening with `immutable=1` would miss every recent exchange. `Pending` rows are
/// left behind by interrupted runs, so a pending exchange counts as running only while it is
/// younger than the active-staleness window *and* Warp is actually running.
enum WarpAgentStore {
    static let providerKey = "warp"
    static let bundleIdentifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview"]

    static var candidateDatabaseURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"),
            home.appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
        ]
    }

    /// The first database that exists, or nil when Warp is not installed.
    static var databaseURL: URL? {
        candidateDatabaseURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct Exchange: Equatable {
        let exchangeID: String
        let conversationID: String
        let startedAt: Date?
        /// `Pending`, `Completed`, `Cancelled`, `Failed` — quotes already stripped.
        let status: String
        let workingDirectory: String?
        /// The first few hundred bytes of the `input` JSON, enough for the prompt text.
        let inputPrefix: String?
    }

    // MARK: - Pure helpers

    /// `2026-06-06 19:20:37.931790` (UTC, as SQLite and Warp write it), with or without fraction.
    static func parseTimestamp(_ text: String) -> Date? {
        for formatter in [fractionalFormatter, plainFormatter] {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let fractionalFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss.SSSSSS")
    private static let plainFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// Strips the JSON quoting Warp stores the status with (`"Completed"`).
    static func normalizedStatus(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }

    /// Maps an exchange status to the hook-style raw state the display ladder understands.
    /// `activeStaleMs` is the same 360 s the hook providers use (REGRESSIONS entry 2).
    static func rawState(status: String, ageMs: Int64, warpRunning: Bool, activeStaleMs: Int64 = 360_000) -> String {
        switch normalizedStatus(status) {
        case "Pending":
            return (warpRunning && ageMs <= activeStaleMs) ? "executing" : "aborted"
        case "Completed": return "stopped"
        case "Cancelled": return "aborted"
        case "Failed": return "error"
        default: return "stopped"
        }
    }

    /// The user's prompt from the exchange input, `[{"Query":{"text":"…"}}]`, read from a
    /// truncated prefix so the full (sometimes multi-hundred-KB) column is never fetched.
    /// Warp has no conversation titles, so a short prompt is the best name available.
    static func queryTitle(fromInputPrefix prefix: String?) -> String? {
        guard let prefix, let queryRange = prefix.range(of: "\"Query\""),
              let textKey = prefix.range(of: "\"text\":\"", range: queryRange.upperBound..<prefix.endIndex) else { return nil }
        var result = ""
        var escaped = false
        for character in prefix[textKey.upperBound...] {
            if escaped {
                switch character {
                case "n", "r", "t": result.append(" ")
                case "u": return finish(result)  // a \u escape: stop rather than misdecode
                default: result.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { break }
            result.append(character)
            if result.count >= 60 { break }
        }
        return finish(result)
    }

    private static func finish(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    /// Newest exchange per conversation; `exchanges` must be newest-first.
    static func newestExchangePerConversation(_ exchanges: [Exchange]) -> [Exchange] {
        var seen: Set<String> = []
        return exchanges.filter { seen.insert($0.conversationID).inserted }
    }

    // MARK: - SQLite

    /// Exchanges started after `since`, newest first, capped. Cached for two seconds because
    /// the WAL fires FSEvents on every Warp write, agent or not.
    static func loadRecentExchanges(databaseURL: URL, since: Date, now: Date = Date()) -> [Exchange] {
        if let cached = exchangeCache, cached.path == databaseURL.path,
           now.timeIntervalSince(cached.at) < cacheTTL {
            return cached.exchanges
        }
        let exchanges = queryExchanges(databaseURL: databaseURL, since: since)
        exchangeCache = (databaseURL.path, now, exchanges)
        return exchanges
    }

    private static let cacheTTL: TimeInterval = 2.0
    private static var exchangeCache: (path: String, at: Date, exchanges: [Exchange])?

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }

    private static func queryExchanges(databaseURL: URL, since: Date) -> [Exchange] {
        guard let db = openReadOnly(databaseURL) else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT exchange_id, conversation_id, start_ts, output_status, working_directory, substr(input, 1, 400)
        FROM ai_queries
        WHERE start_ts >= ?
        ORDER BY start_ts DESC
        LIMIT 64
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let sinceText = plainFormatter.string(from: since)
        sqlite3_bind_text(stmt, 1, sinceText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var exchanges: [Exchange] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let exchangeID = columnText(stmt, 0), let conversationID = columnText(stmt, 1) else { continue }
            exchanges.append(Exchange(
                exchangeID: exchangeID,
                conversationID: conversationID,
                startedAt: columnText(stmt, 2).flatMap(parseTimestamp),
                status: normalizedStatus(columnText(stmt, 3) ?? ""),
                workingDirectory: columnText(stmt, 4),
                inputPrefix: columnText(stmt, 5)
            ))
        }
        return exchanges
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    // MARK: - Sessions

    /// The window of exchanges worth reading for a given staleness.
    static func since(staleMinutes: Int, now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(staleMinutes * 60))
    }

    /// Read + map, in one call. Convenient for tests and one-shot readers; the monitor reads on a
    /// worker and maps on the main actor instead (see `sessions(exchanges:)`), because the
    /// database sits in Warp's group container and the first open raises macOS's "access data
    /// from other apps" prompt, which blocks the calling thread until it is answered.
    static func sessions(
        databaseURL: URL? = databaseURL,
        staleMinutes: Int,
        collapseSeconds: Int,
        inactiveSeconds: Int,
        warpRunning: Bool,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        guard let databaseURL else { return [] }
        let exchanges = loadRecentExchanges(databaseURL: databaseURL, since: since(staleMinutes: staleMinutes, now: now), now: now)
        return sessions(exchanges: exchanges, collapseSeconds: collapseSeconds, inactiveSeconds: inactiveSeconds,
                        warpRunning: warpRunning, now: now)
    }

    /// Pure: exchanges already read → sessions as of `now`. No I/O, safe on the main actor.
    static func sessions(
        exchanges: [Exchange],
        collapseSeconds: Int,
        inactiveSeconds: Int,
        warpRunning: Bool,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let collapseMs = Int64(collapseSeconds) * 1_000
        let inactiveMs = Int64(inactiveSeconds) * 1_000

        let newest = newestExchangePerConversation(exchanges)
        guard !newest.isEmpty else { return [] }

        return newest.map { exchange in
            let startedAt = exchange.startedAt ?? now
            let tsMs = Int64(startedAt.timeIntervalSince1970 * 1000)
            let ageMs = nowMs - tsMs
            let raw = rawState(status: exchange.status, ageMs: ageMs, warpRunning: warpRunning)
            let resolved = AgentTrafficLightMapper.resolveHookState(
                rawState: raw,
                ageMs: ageMs,
                collapseMs: collapseMs,
                inactiveMs: inactiveMs
            )
            let projectName = exchange.workingDirectory
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
            var session = AgentSessionStatus(
                id: "\(providerKey)-\(exchange.conversationID)",
                provider: providerKey,
                conversationID: exchange.conversationID,
                chatName: queryTitle(fromInputPrefix: exchange.inputPrefix),
                projectName: projectName,
                rawState: raw,
                displayState: resolved.state,
                updatedAt: startedAt,
                isVisible: resolved.visible,
                executionStartedAt: nil,
                cwd: exchange.workingDirectory,
                hostPID: nil
            )
            if exchange.status == "Failed" {
                session.toolErrorCount = 1
            }
            return session
        }
    }
}
