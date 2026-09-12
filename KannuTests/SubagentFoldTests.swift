//
//  SubagentFoldTests.swift
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

/// One card per chat: a Claude subagent's hook file (v38 `parent_id`) folds into its parent's card.
final class SubagentFoldTests: XCTestCase {
    typealias M = AgentTrafficLightMapper
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    private func session(_ conversation: String, _ raw: String, _ state: AgentTrafficLightState, visible: Bool = true,
                         name: String? = nil, provider: String = "claude", at offset: TimeInterval = 0) -> AgentSessionStatus {
        AgentSessionStatus(id: "\(provider)-\(conversation)", provider: provider, conversationID: conversation, chatName: name,
                           projectName: "kannu", rawState: raw, displayState: state, updatedAt: t0.addingTimeInterval(offset),
                           isVisible: visible, executionStartedAt: nil, cwd: "/Users/u/kannu", hostPID: 42)
    }

    private func fold(_ sessions: [AgentSessionStatus], _ parents: [String: String]) -> (sessions: [AgentSessionStatus], folded: Set<String>) {
        M.foldSubagentHookSessions(sessions, parentByKey: parents)
    }

    func testASubagentIsNeverACardOfItsOwn() {
        let parent = session("parent", "executing", .executing, name: "Fix the parser")
        let sub = session("a98f5cee53fa799c7", "thinking", .thinking, at: 5)
        let result = fold([parent, sub], ["claude|a98f5cee53fa799c7": "parent"])
        XCTAssertEqual(result.sessions.map(\.conversationID), ["parent"])
        XCTAssertEqual(result.sessions.first?.chatName, "Fix the parser")
        XCTAssertEqual(result.folded, ["a98f5cee53fa799c7"])
    }

    func testASubagentPromptTurnsTheOpenTurnYellow() {
        let parent = session("parent", "thinking", .thinking, name: "Chat", at: 9)
        let sub = session("sub", "awaiting_input", .awaitingInput, at: 5)
        let merged = fold([parent, sub], ["claude|sub": "parent"]).sessions[0]
        XCTAssertEqual(merged.displayState, .awaitingInput, "the parent's own progress cannot hide the prompt")
        XCTAssertEqual(merged.id, "claude-parent")
        XCTAssertEqual(merged.chatName, "Chat")
        XCTAssertEqual(merged.hostPID, 42)
    }

    func testTwoOpenPromptsStayYellowUntilBothAreAnswered() {
        let parent = session("parent", "executing", .executing)
        let asking = session("subA", "awaiting_input", .awaitingInput, at: 1)
        let working = session("subB", "executing", .executing, at: 2)
        for order in [[parent, asking, working], [parent, working, asking]] {
            XCTAssertEqual(fold(order, ["claude|subA": "parent", "claude|subB": "parent"]).sessions[0].displayState, .awaitingInput)
        }
    }

    func testALeftoverSubagentNeverRelightsAFinishedTurn() {
        var sub = session("sub", "thinking", .thinking, at: 30)
        sub.sightings = HookSightings(secrets: [SecretSighting(kind: .npmToken, location: .toolInput, tool: "Bash", prefix: "npm_",
                                                               length: 40, fingerprint: "0123456789ab", eventCount: 1,
                                                               firstSeenMs: 1_788_000_000_000, lastSeenMs: 1_788_000_000_000)])
        let parent = session("parent", "stopped", .stopped, name: "Chat")
        let merged = fold([parent, sub], ["claude|sub": "parent"]).sessions[0]
        XCTAssertEqual(merged.displayState, .stopped, "no green after the chat finished")
        XCTAssertEqual(merged.sightings.secrets.count, 1, "but what the subagent did still belongs to the chat")
    }

    func testAnAgedParentMidRunShowsTheSubagentsLight() {
        let parent = session("parent", "executing", .executing, visible: false)
        let sub = session("sub", "executing", .executing, at: 400)
        let merged = fold([parent, sub], ["claude|sub": "parent"]).sessions[0]
        XCTAssertTrue(merged.isVisible)
        XCTAssertEqual(merged.displayState, .executing)
        XCTAssertEqual(merged.updatedAt, t0.addingTimeInterval(400))
    }

    func testWithoutAParentFileAStandInCarriesTheParentsIdAndGetsItsName() {
        let sub = session("sub", "executing", .executing)
        let result = fold([sub], ["claude|sub": "parent-uuid"])
        let standIn = result.sessions[0]
        XCTAssertEqual(standIn.id, "claude-parent-uuid")
        XCTAssertEqual(standIn.conversationID, "parent-uuid")
        XCTAssertNil(standIn.chatName)
        let passive = session("parent-uuid", "executing", .executing, name: "The real title")
        let named = M.reconcileClaudeSessions(hookSessions: result.sessions, passiveSessions: [passive], deadPIDConversationIDs: [],
                                              collapseMs: 60_000, inactiveMs: 120_000, nowMs: 1_788_000_000_000)
        XCTAssertEqual(named.first { $0.conversationID == "parent-uuid" }?.chatName, "The real title")
    }

    func testProvidersNeverCrossAndAnEmptyMapChangesNothing() {
        let cursor = session("same", "executing", .executing, provider: "cursor")
        let claudeSub = session("sub", "awaiting_input", .awaitingInput)
        let result = fold([cursor, claudeSub], ["claude|sub": "same"])
        XCTAssertEqual(result.sessions.first { $0.provider == "cursor" }?.displayState, .executing, "a Cursor card is not a Claude parent")
        XCTAssertEqual(result.sessions.count, 2, "a Claude stand-in beside the Cursor card")
        let untouched = [cursor, claudeSub]
        XCTAssertEqual(fold(untouched, [:]).sessions, untouched)
    }

    func testTheAggregateLightIsUnchangedWhileTheTurnIsOpen() {
        let turnStates: [(String, AgentTrafficLightState)] = [("executing", .executing), ("thinking", .thinking), ("awaiting_input", .awaitingInput)]
        for (parentRaw, parentState) in turnStates {
            for (subRaw, subState) in turnStates {
                let parent = session("parent", parentRaw, parentState)
                let sub = session("sub", subRaw, subState, at: 1)
                let folded = fold([parent, sub], ["claude|sub": "parent"]).sessions
                XCTAssertEqual(M.resolveDisplayState(from: folded), M.resolveDisplayState(from: [parent, sub]), "\(parentRaw) + \(subRaw)")
            }
        }
    }

    // MARK: - v39: the turn is the parent's, with its subagents' tool calls

    private func turn(_ start: TimeInterval, calls: Int, ended: TimeInterval? = nil) -> HookTurn {
        HookTurn(startedAt: t0.addingTimeInterval(start), endedAt: ended.map { t0.addingTimeInterval($0) }, toolCalls: calls,
                 transcriptPath: "/Users/u/.claude/projects/p/parent.jsonl", transcriptOffset: 10)
    }

    func testSubagentToolCallsAddToTheOpenTurn() {
        var parent = session("parent", "executing", .executing, name: "Chat")
        parent.turn = turn(0, calls: 5)
        var subA = session("subA", "thinking", .thinking, at: 2)
        subA.turn = turn(1, calls: 7)
        var subB = session("subB", "awaiting_input", .awaitingInput, at: 3)
        subB.turn = turn(2, calls: 1)
        let merged = fold([parent, subA, subB], ["claude|subA": "parent", "claude|subB": "parent"]).sessions[0]
        XCTAssertEqual(merged.displayState, .awaitingInput, "the winning arm")
        XCTAssertEqual(merged.turn?.toolCalls, 13)
        XCTAssertEqual(merged.turn?.startedAt, parent.turn?.startedAt, "the request is the parent's")
        XCTAssertEqual(merged.turn?.transcriptPath, parent.turn?.transcriptPath)
    }

    func testALeftoverSubagentAddsNothing() {
        var parent = session("parent", "stopped", .stopped)
        parent.turn = turn(100, calls: 2, ended: 200)
        var sub = session("sub", "thinking", .thinking, at: 50)
        sub.turn = turn(10, calls: 40)
        let merged = fold([parent, sub], ["claude|sub": "parent"]).sessions[0]
        XCTAssertEqual(merged.turn?.toolCalls, 2, "a subagent from an earlier request is not this one's")
        XCTAssertEqual(merged.turn?.endedAt, parent.turn?.endedAt)
    }

    func testAStandInHasNoTurnAndATurnlessParentNeverAdoptsOne() {
        var sub = session("sub", "executing", .executing)
        sub.turn = turn(0, calls: 3)
        XCTAssertNil(fold([sub], ["claude|sub": "parent"]).sessions[0].turn, "a stand-in has no request of its own")
        let parent = session("parent", "executing", .executing)
        for order in [[parent, sub], [sub, parent]] {
            XCTAssertNil(fold(order, ["claude|sub": "parent"]).sessions.first { $0.conversationID == "parent" }?.turn,
                         "self ?? source would have handed the parent the subagent's turn")
        }
    }

    func testConversationIDsAreValidated() {
        XCTAssertTrue(M.isHookConversationID("a493e20e-4ef1-487b-98c1-98917240f969"))
        XCTAssertTrue(M.isHookConversationID("a98f5cee53fa799c7"))
        XCTAssertFalse(M.isHookConversationID(""))
        XCTAssertFalse(M.isHookConversationID("../etc"))
        XCTAssertFalse(M.isHookConversationID(String(repeating: "a", count: 65)))
    }
}
