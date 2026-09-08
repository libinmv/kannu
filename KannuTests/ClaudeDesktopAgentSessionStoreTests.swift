//
//  ClaudeDesktopAgentSessionStoreTests.swift
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

import XCTest

/// Fixture-driven: no machine in CI (or the one this was written on) has Claude Desktop's
/// agent mode enabled, so the record shapes come from the SDK stream contract that the
/// `audit.jsonl` mirrors. Runtime-unverified; see the PR.
final class ClaudeDesktopAgentSessionStoreTests: XCTestCase {
    typealias Store = ClaudeDesktopAgentSessionStore

    private let initLine = #"{"type":"system","subtype":"init","model":"claude-sonnet-4-6","cwd":"/Users/me/proj","tools":["Bash"],"mcp_servers":[{"name":"github"}]}"#
    private let userPrompt = #"{"type":"user","message":{"role":"user","content":"fix the bug"}}"#
    private let assistantToolUse = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use"}}"#
    private let toolResultError = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#
    private let toolResultOK = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private let assistantText = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#
    private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200}"#
    private let rateWarning = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour"}}"#
    private let rateRejected = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1788900000}}"#

    private func join(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    func testInitRecordYieldsModeModelAndCwd() {
        let parsed = Store.parse(head: join([initLine, userPrompt]), tail: join([userPrompt]))
        XCTAssertEqual(parsed.model, "claude-sonnet-4-6")
        XCTAssertEqual(parsed.cwd, "/Users/me/proj")
        XCTAssertEqual(parsed.rawState, "thinking", "a prompt with no answer yet owes a response")
    }

    func testNewestRecordDecidesTheState() {
        XCTAssertEqual(Store.parse(head: nil, tail: join([userPrompt, assistantToolUse])).rawState, "executing")
        XCTAssertEqual(Store.parse(head: nil, tail: join([userPrompt, assistantToolUse, toolResultOK])).rawState, "thinking")
        XCTAssertEqual(Store.parse(head: nil, tail: join([userPrompt, assistantText])).rawState, "stopped")
        XCTAssertEqual(Store.parse(head: nil, tail: join([userPrompt, assistantText, resultLine])).rawState, "stopped")
        XCTAssertEqual(Store.parse(head: nil, tail: "").rawState, "idle")
    }

    func testRateLimitRejectedBecomesQuotaExceeded() {
        let parsed = Store.parse(head: nil, tail: join([userPrompt, assistantToolUse, rateRejected]))
        XCTAssertEqual(parsed.rawState, "quota_exceeded")

        let warned = Store.parse(head: nil, tail: join([userPrompt, rateWarning, assistantToolUse]))
        XCTAssertEqual(warned.rawState, "executing", "a warning-level event is bookkeeping, not a state")
    }

    func testToolErrorsAreCountedPerTurn() {
        let tail = join([userPrompt, assistantToolUse, toolResultError, assistantToolUse, toolResultError,
                         assistantToolUse, toolResultOK, assistantText, resultLine])
        XCTAssertEqual(Store.parse(head: nil, tail: tail).toolErrorCount, 2)
        // Errors from an earlier turn do not leak into the current one.
        let twoTurns = join([userPrompt, assistantToolUse, toolResultError, assistantText, resultLine,
                             userPrompt, assistantToolUse, toolResultOK, assistantText, resultLine])
        XCTAssertEqual(Store.parse(head: nil, tail: twoTurns).toolErrorCount, 0)
    }

    func testSessionIdentityFromDirectoryNames() {
        let base = URL(fileURLWithPath: "/tmp/root/user/org")
        let interactive = base.appendingPathComponent("local_ABC-123/audit.jsonl")
        let dispatch = base.appendingPathComponent("agent/local_ditto_XYZ/audit.jsonl")
        XCTAssertEqual(Store.sessionIdentity(forAuditLog: interactive)?.id, "ABC-123")
        XCTAssertEqual(Store.sessionIdentity(forAuditLog: interactive)?.isDispatch, false)
        XCTAssertEqual(Store.sessionIdentity(forAuditLog: dispatch)?.id, "XYZ")
        XCTAssertEqual(Store.sessionIdentity(forAuditLog: dispatch)?.isDispatch, true)
        XCTAssertNil(Store.sessionIdentity(forAuditLog: base.appendingPathComponent("notes/audit.jsonl")))
    }

    func testSessionsFromAFixtureTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-desktop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let live = root.appendingPathComponent("u1/o1/local_11111111-1111-1111-1111-111111111111")
        let dispatch = root.appendingPathComponent("u1/o1/agent/local_ditto_22222222-2222-2222-2222-222222222222")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: dispatch, withIntermediateDirectories: true)
        try join([initLine, userPrompt, assistantToolUse]).write(to: live.appendingPathComponent("audit.jsonl"), atomically: true, encoding: .utf8)
        try join([initLine, userPrompt, assistantText, resultLine])
            .write(to: dispatch.appendingPathComponent("audit.jsonl"), atomically: true, encoding: .utf8)

        let sessions = Store.sessions(root: root, staleMinutes: 30, collapseSeconds: 60, inactiveSeconds: 60, now: Date())
            .sorted { $0.conversationID < $1.conversationID }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].provider, "claudedesktop")
        XCTAssertEqual(sessions[0].displayState, .executing)
        XCTAssertEqual(sessions[0].projectName, "proj")
        XCTAssertEqual(sessions[0].cwd, "/Users/me/proj")
        XCTAssertNil(sessions[0].hostPID, "no process to activate; click-through goes by bundle id")
        XCTAssertEqual(sessions[1].displayState, .stopped)
        XCTAssertEqual(sessions[1].chatName, "Dispatch agent")
    }

    func testParsedLogsAreCachedButInvalidateWhenTheFileGrows() throws {
        // The cache is keyed on (mtime, size): a repeat scan must return the same verdict, and an
        // appended record must still be seen. Pinning both halves, since a cache that never
        // invalidated would freeze a session's state on the main actor's next pass.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-desktop-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("u1/o1/local_33333333-3333-3333-3333-333333333333")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("audit.jsonl")
        try join([initLine, userPrompt, assistantToolUse]).write(to: log, atomically: true, encoding: .utf8)

        func scan() -> AgentSessionStatus? {
            Store.sessions(root: root, staleMinutes: 30, collapseSeconds: 60, inactiveSeconds: 60, now: Date()).first
        }
        XCTAssertEqual(scan()?.displayState, .executing)
        XCTAssertEqual(scan()?.displayState, .executing, "a second pass must agree with the first")

        // Append a finished turn. Same path, new size — the cached parse must be discarded.
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data(join([assistantText, resultLine]).utf8))
        try handle.close()
        XCTAssertEqual(scan()?.displayState, .stopped, "an appended record must invalidate the cache")
    }

    func testMissingRootYieldsNothing() {
        let missing = URL(fileURLWithPath: "/nonexistent/kannu-\(UUID().uuidString)")
        XCTAssertEqual(Store.sessions(root: missing, staleMinutes: 30, collapseSeconds: 5, inactiveSeconds: 5), [])
    }
}
