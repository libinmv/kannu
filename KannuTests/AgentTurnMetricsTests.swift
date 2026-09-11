//
//  AgentTurnMetricsTests.swift
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

/// The hook's turn (v39) as Kannu reads it: the status file is untrusted, so every key is checked
/// again, and only a canonical path under ~/.claude/projects is ever followed for tokens.
final class AgentTurnMetricsTests: XCTestCase {
    private let home = "/Users/u"
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private var path: String { home + "/.claude/projects/-Users-u-app/c.jsonl" }

    private func parse(_ json: [String: Any]) -> HookTurn? { HookTurn(hookFile: json, home: home, now: now) }

    func testReadsTheTurn() throws {
        let turn = try XCTUnwrap(parse(["turn_started_ms": nowMs - 60_000, "turn_ended_ms": nowMs - 1_000, "turn_tool_calls": 12,
                                        "transcript_path": path, "turn_transcript_offset": 4096]))
        XCTAssertEqual(turn.startedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(turn.endedAt, now.addingTimeInterval(-1))
        XCTAssertEqual(turn.toolCalls, 12)
        XCTAssertEqual(turn.transcriptPath, path)
        XCTAssertEqual(turn.transcriptOffset, 4096)
        XCTAssertNil(try XCTUnwrap(parse(["turn_started_ms": nowMs])).endedAt, "an open turn")
    }

    func testNoPlausibleStartIsNoTurn() {
        XCTAssertNil(parse([:]))
        XCTAssertNil(parse(["turn_started_ms": true]))
        XCTAssertNil(parse(["turn_started_ms": "1789000000000"]))
        XCTAssertNil(parse(["turn_started_ms": 1_788_999_999_000.5]))
        XCTAssertNil(parse(["turn_started_ms": 999_999_999_999]), "seconds, not milliseconds")
        XCTAssertNil(parse(["turn_started_ms": nowMs + 61_000]), "a start in the future")
        XCTAssertNotNil(parse(["turn_started_ms": nowMs + 59_000]), "the hook's own slack")
    }

    func testBadFieldsAreDroppedOrClamped() throws {
        let start = nowMs - 10_000
        XCTAssertNil(try XCTUnwrap(parse(["turn_started_ms": start, "turn_ended_ms": start - 1])).endedAt, "an end before the start")
        XCTAssertNil(try XCTUnwrap(parse(["turn_started_ms": start, "turn_ended_ms": nowMs + 120_000])).endedAt)
        XCTAssertEqual(try XCTUnwrap(parse(["turn_started_ms": start, "turn_tool_calls": -3])).toolCalls, 0)
        XCTAssertEqual(try XCTUnwrap(parse(["turn_started_ms": start, "turn_tool_calls": 1_000_000_000])).toolCalls, 99_999)
        XCTAssertEqual(try XCTUnwrap(parse(["turn_started_ms": start, "turn_tool_calls": true])).toolCalls, 0)
        let noPath = try XCTUnwrap(parse(["turn_started_ms": start, "turn_transcript_offset": 10]))
        XCTAssertNil(noPath.transcriptOffset, "an offset means nothing without a followable path")
        XCTAssertNil(try XCTUnwrap(parse(["turn_started_ms": start, "transcript_path": path, "turn_transcript_offset": -1])).transcriptOffset)
        XCTAssertNil(try XCTUnwrap(parse(["turn_started_ms": start, "transcript_path": path, "turn_transcript_offset": false])).transcriptOffset)
        let badPath = try XCTUnwrap(parse(["turn_started_ms": start, "transcript_path": "/etc/passwd", "turn_transcript_offset": 5]))
        XCTAssertNil(badPath.transcriptPath)
        XCTAssertNil(badPath.transcriptOffset)
    }

    func testOnlyACanonicalMainTranscriptUnderProjectsIsFollowable() {
        let projects = home + "/.claude/projects"
        XCTAssertTrue(HookTurn.isFollowableTranscript(path, home: home))
        for bad in [
            "",
            "c.jsonl",
            "/tmp/c.jsonl",
            home + "/Documents/c.jsonl",
            projects + "/p/c.txt",
            projects + "/p/../../../Documents/c.jsonl",
            projects + "/p/./c.jsonl",
            projects + "//p/c.jsonl",
            projects + "/p/c/subagents/agent-1.jsonl",
            projects + "/p/caf\u{e9}.jsonl",
            projects + "/p/c\n.jsonl",
            projects + "/" + String(repeating: "a", count: 1100) + ".jsonl",
            "/Users/u2/.claude/projects/p/c.jsonl",
        ] {
            XCTAssertFalse(HookTurn.isFollowableTranscript(bad, home: home), bad)
        }
        XCTAssertFalse(HookTurn.isFollowableTranscript(path, home: ""))
    }

    func testFoldingKeepsTheParentsTurn() {
        let parent = HookTurn(startedAt: now, toolCalls: 4, transcriptPath: path, transcriptOffset: 1)
        let sub = HookTurn(startedAt: now.addingTimeInterval(5), toolCalls: 6)
        XCTAssertEqual(HookTurn.folding(sub, into: parent)?.toolCalls, 10)
        XCTAssertEqual(HookTurn.folding(sub, into: parent)?.transcriptPath, path)
        XCTAssertEqual(HookTurn.folding(HookTurn(startedAt: now.addingTimeInterval(-1), toolCalls: 6), into: parent)?.toolCalls, 4)
        XCTAssertEqual(HookTurn.folding(nil, into: parent), parent)
        XCTAssertNil(HookTurn.folding(sub, into: nil))
        XCTAssertEqual(HookTurn.folding(HookTurn(startedAt: now, toolCalls: 99_999), into: parent)?.toolCalls, 99_999)
    }

    func testTheTurnRidesCarryingExtrasAsSelfThenSource() {
        let mine = HookTurn(startedAt: now, toolCalls: 1)
        let theirs = HookTurn(startedAt: now, toolCalls: 2)
        var a = AgentSessionStatus(id: "claude-c", provider: "claude", conversationID: "c", chatName: nil, projectName: nil,
                                   rawState: "executing", displayState: .executing, updatedAt: now, isVisible: true,
                                   executionStartedAt: nil)
        var b = a
        b.turn = theirs
        XCTAssertEqual(a.carryingExtras(from: b).turn, theirs, "nil yields")
        a.turn = mine
        XCTAssertEqual(a.carryingExtras(from: b).turn, mine, "self wins")
        XCTAssertEqual(a.withDisplayState(.stopped, visible: true).turn, mine)
        XCTAssertEqual(a.replacingChatName("x").turn, mine)
        XCTAssertEqual(a.replacingProjectName("y").turn, mine)
    }
}
