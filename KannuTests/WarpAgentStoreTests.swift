//
//  WarpAgentStoreTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import SQLite3
import XCTest

/// Builds a throwaway `warp.sqlite` with the three tables the store reads and checks the
/// state ladder against it. The schema mirrors the columns observed in Warp 0.2026.09.
final class WarpAgentStoreTests: XCTestCase {
    typealias Store = WarpAgentStore

    private var databaseURL: URL!
    private var now: Date!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-warp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databaseURL = dir.appendingPathComponent("warp.sqlite")
        now = Date()
        try exec("""
        CREATE TABLE agent_conversations (id INTEGER PRIMARY KEY, conversation_id TEXT NOT NULL,
            conversation_data TEXT NOT NULL, last_modified_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE ai_queries (id INTEGER PRIMARY KEY, exchange_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
            start_ts DATETIME NOT NULL, input TEXT NOT NULL, working_directory TEXT, output_status TEXT NOT NULL,
            model_id TEXT NOT NULL DEFAULT '');
        CREATE TABLE mcp_server_installations (id TEXT PRIMARY KEY, templatable_mcp_server TEXT NOT NULL,
            template_version_ts TIMESTAMP NOT NULL, variable_values TEXT NOT NULL, restore_running BOOLEAN NOT NULL,
            last_modified_at TIMESTAMP NOT NULL);
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func timestamp(secondsAgo: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func insertExchange(_ id: String, conversation: String, secondsAgo: TimeInterval, status: String,
                                cwd: String = "/Users/me/proj", prompt: String = "Run the tests") throws {
        let input = #"[{"Query":{"text":"\#(prompt)","context":[{"Directory":{"pwd":"\#(cwd)"}}]}}]"#
        try exec("""
        INSERT INTO ai_queries (exchange_id, conversation_id, start_ts, input, working_directory, output_status, model_id)
        VALUES ('\(id)', '\(conversation)', '\(timestamp(secondsAgo: secondsAgo))', '\(input)', '\(cwd)', '"\(status)"', 'auto');
        """)
    }

    private func sessions(warpRunning: Bool = true) -> [AgentSessionStatus] {
        Store.sessions(databaseURL: databaseURL, staleMinutes: 30, collapseSeconds: 60, inactiveSeconds: 60,
                       warpRunning: warpRunning, now: now)
    }

    // MARK: - Pure helpers

    func testTimestampParsing() {
        XCTAssertNotNil(Store.parseTimestamp("2026-06-06 19:20:37.931790"))
        XCTAssertNotNil(Store.parseTimestamp("2026-08-31 08:00:06"))
        XCTAssertNil(Store.parseTimestamp("yesterday"))
        let parsed = Store.parseTimestamp("2026-01-01 00:00:00")!
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_767_225_600, accuracy: 1, "interpreted as UTC")
    }

    func testStatusLadder() {
        XCTAssertEqual(Store.rawState(status: "\"Pending\"", ageMs: 10_000, warpRunning: true), "executing")
        XCTAssertEqual(Store.rawState(status: "Pending", ageMs: 400_000, warpRunning: true), "aborted", "a stale Pending row is an interrupted run")
        XCTAssertEqual(Store.rawState(status: "Pending", ageMs: 10_000, warpRunning: false), "aborted", "nothing runs while Warp is closed")
        XCTAssertEqual(Store.rawState(status: "Completed", ageMs: 0, warpRunning: true), "stopped")
        XCTAssertEqual(Store.rawState(status: "Cancelled", ageMs: 0, warpRunning: true), "aborted")
        XCTAssertEqual(Store.rawState(status: "Failed", ageMs: 0, warpRunning: true), "error")
    }

    func testQueryTitleFromTruncatedInput() {
        XCTAssertEqual(Store.queryTitle(fromInputPrefix: #"[{"Query":{"text":"Run the project tests","context":[]}}]"#), "Run the project tests")
        XCTAssertEqual(Store.queryTitle(fromInputPrefix: #"[{"Query":{"text":"say \"hi\"\nplease","context""#), "say \"hi\" please")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(Store.queryTitle(fromInputPrefix: #"[{"Query":{"text":"\#(long)"#)?.count, 60)
        XCTAssertNil(Store.queryTitle(fromInputPrefix: #"[{"ActionResult":{"id":"x"}}]"#), "tool results are not prompts")
        XCTAssertNil(Store.queryTitle(fromInputPrefix: nil))
    }

    // MARK: - Against a database

    func testMissingDatabaseYieldsNothing() {
        XCTAssertEqual(Store.sessions(databaseURL: nil, staleMinutes: 30, collapseSeconds: 5, inactiveSeconds: 5, warpRunning: true), [])
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).sqlite")
        XCTAssertEqual(Store.sessions(databaseURL: missing, staleMinutes: 30, collapseSeconds: 5, inactiveSeconds: 5, warpRunning: true), [])
    }

    func testFreshPendingExchangeIsExecutingAndCarriesPromptAndProject() throws {
        try insertExchange("e1", conversation: "c1", secondsAgo: 20, status: "Pending", prompt: "Fix the flaky test")
        let result = sessions()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].provider, "warp")
        XCTAssertEqual(result[0].displayState, .executing)
        XCTAssertTrue(result[0].isVisible)
        XCTAssertEqual(result[0].chatName, "Fix the flaky test")
        XCTAssertEqual(result[0].projectName, "proj")
        XCTAssertEqual(result[0].cwd, "/Users/me/proj")
    }

    func testStalePendingRowIsNotShownAsRunning() throws {
        try insertExchange("e1", conversation: "c1", secondsAgo: 20 * 60, status: "Pending")
        let result = sessions()
        XCTAssertEqual(result.count, 1)
        XCTAssertNotEqual(result[0].displayState, .executing)
        XCTAssertFalse(result[0].isVisible, "twenty minutes past collapse + inactive, it has aged out")
    }

    func testCompletedFailedAndCancelled() throws {
        try insertExchange("e1", conversation: "c1", secondsAgo: 5, status: "Completed")
        try insertExchange("e2", conversation: "c2", secondsAgo: 5, status: "Failed")
        try insertExchange("e3", conversation: "c3", secondsAgo: 5, status: "Cancelled")
        let byConversation = Dictionary(uniqueKeysWithValues: sessions().map { ($0.conversationID, $0) })
        XCTAssertEqual(byConversation["c1"]?.displayState, .stopped)
        XCTAssertEqual(byConversation["c1"]?.toolErrorCount, 0)
        XCTAssertEqual(byConversation["c2"]?.displayState, .stopped)
        XCTAssertEqual(byConversation["c2"]?.toolErrorCount, 1)
        XCTAssertEqual(byConversation["c3"]?.displayState, .stopped)
    }

    func testNewestExchangeWinsPerConversation() throws {
        try insertExchange("old", conversation: "c1", secondsAgo: 300, status: "Completed", prompt: "first")
        try insertExchange("new", conversation: "c1", secondsAgo: 10, status: "Pending", prompt: "second")
        let result = sessions()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].chatName, "second")
        XCTAssertEqual(result[0].displayState, .executing)
    }

    func testExchangesOutsideTheWindowAreIgnored() throws {
        try insertExchange("e1", conversation: "c1", secondsAgo: 2 * 3600, status: "Completed")
        XCTAssertEqual(sessions(), [])
    }
}
