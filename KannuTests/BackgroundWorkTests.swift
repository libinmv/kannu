//
//  BackgroundWorkTests.swift
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

/// A Claude chat whose turn ended with background agents still running is not finished: Claude Code
/// goes on working, and spending tokens, until they do (docs/REGRESSIONS.md entry 5, 2026-10-04
/// addendum). It stays lit while the hook's count at the Stop (v44 `turn_bg_agents`) and Claude's
/// own session record (`busy`) both say so, and ends the moment Claude says `idle`.
final class BackgroundWorkTests: XCTestCase {
    typealias M = AgentTrafficLightMapper
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private let nowMs: Int64 = 1_788_000_600_000

    private func session(_ raw: String, _ state: AgentTrafficLightState, conversation: String = "chat",
                         visible: Bool = true, provider: String = "claude", at offset: TimeInterval = 0,
                         turn: HookTurn? = nil) -> AgentSessionStatus {
        var session = AgentSessionStatus(id: "\(provider)-\(conversation)", provider: provider, conversationID: conversation,
                                         chatName: "Background chat", projectName: "kannu", rawState: raw, displayState: state,
                                         updatedAt: t0.addingTimeInterval(offset), isVisible: visible, executionStartedAt: nil,
                                         cwd: "/Users/u/kannu", hostPID: 42)
        session.turn = turn
        return session
    }

    /// Started at t0, ended a minute later, leaving `agents` running.
    private func endedTurn(agents: Int) -> HookTurn {
        HookTurn(startedAt: t0, endedAt: t0.addingTimeInterval(60), toolCalls: 12, backgroundAgents: agents)
    }

    private func reconcile(_ hooks: [AgentSessionStatus], passive: [AgentSessionStatus] = [], dead: Set<String> = [],
                           ongoing: Set<String>) -> [AgentSessionStatus] {
        M.reconcileClaudeSessions(hookSessions: hooks, passiveSessions: passive, deadPIDConversationIDs: dead,
                                  collapseMs: 60_000, inactiveMs: 120_000, nowMs: nowMs, claudeWorkOngoingIDs: ongoing)
    }

    // MARK: - Claude's own word

    func testClaudesSessionRecordSaysWhetherItsWorkGoesOn() {
        XCTAssertTrue(M.claudeWorkOngoing(status: "busy", statusUpdatedAtMs: 1, nowMs: nowMs), "a turn or a background agent")
        XCTAssertTrue(M.claudeWorkOngoing(status: "waiting", statusUpdatedAtMs: 1, nowMs: nowMs), "a prompt is up: not over")
        XCTAssertFalse(M.claudeWorkOngoing(status: "idle", statusUpdatedAtMs: nowMs - 60_000, nowMs: nowMs))
        XCTAssertFalse(M.claudeWorkOngoing(status: "shell", statusUpdatedAtMs: nowMs, nowMs: nowMs),
                       "only a background command: no agent is spending tokens")
        for status in [nil, "", "BUSY", "running", "done"] {
            XCTAssertFalse(M.claudeWorkOngoing(status: status, statusUpdatedAtMs: nowMs, nowMs: nowMs), "\(status ?? "nil")")
        }
    }

    func testAFreshIdleCountsForAMomentAndTheMonitorIsToldWhenItStops() {
        let justNow = nowMs - 1_000
        XCTAssertTrue(M.claudeWorkOngoing(status: "idle", statusUpdatedAtMs: justNow, nowMs: nowMs),
                      "between an agent finishing and Claude waking to read its result")
        XCTAssertEqual(M.claudeIdleGraceEndMs(status: "idle", statusUpdatedAtMs: justNow, nowMs: nowMs),
                       justNow + M.claudeIdleGraceMs)
        XCTAssertNil(M.claudeIdleGraceEndMs(status: "idle", statusUpdatedAtMs: nowMs - M.claudeIdleGraceMs, nowMs: nowMs))
        XCTAssertNil(M.claudeIdleGraceEndMs(status: "busy", statusUpdatedAtMs: justNow, nowMs: nowMs))
        XCTAssertNil(M.claudeIdleGraceEndMs(status: "idle", statusUpdatedAtMs: nowMs + 5_000, nowMs: nowMs),
                     "a clock in the future is untrusted input")
        XCTAssertNil(M.claudeIdleGraceEndMs(status: "idle", statusUpdatedAtMs: nil, nowMs: nowMs))
    }

    // MARK: - The card

    func testAChatWithAgentsStillRunningStaysGreenWhileClaudeSaysSo() {
        let hook = session("stopped", .stopped, turn: endedTurn(agents: 3))
        // What a finished main turn looks like from the transcript: newer than the hook's Stop.
        let passive = session("stopped", .stopped, at: 30)
        let card = reconcile([hook], passive: [passive], ongoing: ["chat"])[0]
        XCTAssertEqual(card.displayState, .thinking)
        XCTAssertTrue(card.isVisible)
        XCTAssertEqual(card.chatName, "Background chat")
        XCTAssertEqual(card.backgroundWorkSuffix, " · " + String(localized: "agents in background"))
    }

    func testTheMomentClaudeSaysIdleTheChatIsFinished() {
        let hook = session("stopped", .stopped, turn: endedTurn(agents: 3))
        let card = reconcile([hook], passive: [session("stopped", .stopped, at: 30)], ongoing: [])[0]
        XCTAssertEqual(card.displayState, .stopped)
        XCTAssertEqual(card.backgroundWorkSuffix, "")
    }

    func testNeitherSignalAloneLightsTheChat() {
        // Busy with nothing left at the Stop: the moment before Claude writes idle.
        let nothingLeft = session("stopped", .stopped, turn: endedTurn(agents: 0))
        XCTAssertEqual(reconcile([nothingLeft], ongoing: ["chat"])[0].displayState, .stopped)
        // No turn (a hook before v39), or a turn still open: nothing to say about background work.
        XCTAssertEqual(reconcile([session("stopped", .stopped)], ongoing: ["chat"])[0].displayState, .stopped)
        XCTAssertEqual(HookTurn(startedAt: t0, backgroundAgents: 4).backgroundAgents, 0, "an open turn leaves nothing behind")
    }

    func testADeadProcessIsNeverBackgroundWork() {
        let hook = session("stopped", .stopped, turn: endedTurn(agents: 2))
        let card = reconcile([hook], dead: ["chat"], ongoing: ["chat"])[0]
        XCTAssertNotEqual(card.displayState, .thinking)
    }

    func testYellowIsStillOnlyTheHooksToGive() {
        // Claude's idle notice after the Stop is the hook's yellow; background work keeps it.
        let waiting = session("awaiting_input", .awaitingInput, turn: endedTurn(agents: 1))
        XCTAssertEqual(reconcile([waiting], ongoing: ["chat"])[0].displayState, .awaitingInput)
        // Claude's own "waiting" never paints yellow by itself: the card is green, not yellow.
        let stopped = session("stopped", .stopped, turn: endedTurn(agents: 1))
        XCTAssertEqual(reconcile([stopped], ongoing: ["chat"])[0].displayState, .thinking)
    }

    func testOtherProvidersAreUntouched() {
        let codex = session("stopped", .stopped, provider: "codex", turn: endedTurn(agents: 2))
        XCTAssertEqual(reconcile([codex], ongoing: ["chat"])[0].displayState, .stopped)
        XCTAssertFalse(M.isClaudeBackgroundWork(codex, workOngoingIDs: ["chat"]))
    }

    func testRescansWhileTheAgentsRunChangeNothing() {
        // No pulse (entry 10): the same evidence gives the same list.
        let hook = session("stopped", .stopped, turn: endedTurn(agents: 2))
        let first = reconcile([hook], ongoing: ["chat"])
        let second = reconcile([hook], ongoing: ["chat"])
        XCTAssertEqual(first, second)
        XCTAssertFalse(M.pulseRelevantChange(from: first, to: second))
    }

    func testTheClockKeepsRunningFromThePromptUntilClaudeIsDone() {
        let turn = endedTurn(agents: 2)
        XCTAssertEqual(AgentTurnDisplay.duration(turn: turn, executionStartedAt: nil, state: .thinking,
                                                 hookReportsWork: false, updatedAt: t0.addingTimeInterval(60)),
                       .live(since: t0))
        XCTAssertEqual(AgentTurnDisplay.duration(turn: turn, executionStartedAt: nil, state: .stopped,
                                                 hookReportsWork: false, updatedAt: t0.addingTimeInterval(60)),
                       .ended(60), "once Claude says idle the card is stopped, and the request ran this long")
    }

    // MARK: - Subagents

    func testABackgroundAgentWaitingOnPermissionTurnsTheChatYellow() {
        let parent = session("stopped", .stopped, turn: endedTurn(agents: 1))
        let asking = session("awaiting_input", .awaitingInput, conversation: "sub", at: 120)
        let folded = M.foldSubagentHookSessions([parent, asking], parentByKey: ["claude|sub": "chat"],
                                                claudeWorkOngoingIDs: ["chat"]).sessions[0]
        XCTAssertEqual(folded.displayState, .awaitingInput)
        XCTAssertEqual(reconcile([folded], ongoing: ["chat"])[0].displayState, .awaitingInput)
    }

    func testWithoutClaudesWordALeftoverSubagentStillNeverRelightsAFinishedChat() {
        let parent = session("stopped", .stopped, turn: endedTurn(agents: 1))
        let leftover = session("thinking", .thinking, conversation: "sub", at: 120)
        let folded = M.foldSubagentHookSessions([parent, leftover], parentByKey: ["claude|sub": "chat"]).sessions[0]
        XCTAssertEqual(folded.displayState, .stopped)
        XCTAssertEqual(reconcile([folded], ongoing: []).first?.displayState, .stopped)
    }

    func testAStoppedSubagentNeverWins() {
        // SubagentStop (v44) ends the agent's own file.
        let parent = session("stopped", .stopped, turn: endedTurn(agents: 2))
        let finished = session("stopped", .stopped, conversation: "sub", at: 120)
        let folded = M.foldSubagentHookSessions([parent, finished], parentByKey: ["claude|sub": "chat"],
                                                claudeWorkOngoingIDs: ["chat"]).sessions[0]
        XCTAssertEqual(folded.rawState, "stopped")
        XCTAssertEqual(reconcile([folded], ongoing: ["chat"])[0].displayState, .thinking, "the chat's own background work")
    }

    // MARK: - Disk and parsing

    func testTheChatsFileOutlivesTheStaleCapOnlyWithBackgroundWork() {
        XCTAssertTrue(M.hookFileOutlivesStaleCap(provider: "claude", rawState: "stopped", processAlive: true,
                                                 namedByFreshSubagent: false, subagentOfOpenTurn: false, backgroundWork: true))
        XCTAssertFalse(M.hookFileOutlivesStaleCap(provider: "claude", rawState: "stopped", processAlive: true,
                                                  namedByFreshSubagent: false, subagentOfOpenTurn: false, backgroundWork: false))
        XCTAssertFalse(M.hookFileOutlivesStaleCap(provider: "codex", rawState: "stopped", processAlive: true,
                                                  namedByFreshSubagent: false, subagentOfOpenTurn: false, backgroundWork: true))
    }

    func testTheCountIsReadOnlyForAnEndedTurnAndClamped() {
        let now = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
        let start = nowMs - 120_000
        func turn(_ extra: [String: Any]) -> HookTurn? {
            var json: [String: Any] = ["turn_started_ms": start]
            json.merge(extra) { $1 }
            return HookTurn(hookFile: json, home: "/Users/u", now: now)
        }
        XCTAssertEqual(turn(["turn_ended_ms": start + 60_000, "turn_bg_agents": 3])?.backgroundAgents, 3)
        XCTAssertEqual(turn(["turn_bg_agents": 3])?.backgroundAgents, 0, "an open turn has nothing left behind")
        XCTAssertEqual(turn(["turn_ended_ms": start + 60_000, "turn_bg_agents": 5_000])?.backgroundAgents, HookTurn.maxBackgroundAgents)
        for hostile: Any in [-4, true, "3", 2.5] {
            XCTAssertEqual(turn(["turn_ended_ms": start + 60_000, "turn_bg_agents": hostile])?.backgroundAgents, 0, "\(hostile)")
        }
    }

    /// The installer's Claude table is not in the logic target, so its two v44 rows are read from source.
    func testTheInstallerHooksASubagentsStartAndEnd() throws {
        let installer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kannu/managers/AgentStatus/AgentHookInstaller.swift")
        let source = try String(contentsOf: installer, encoding: .utf8)
        XCTAssertTrue(source.contains(#"("SubagentStart", nil, "", "thinking"),"#))
        XCTAssertTrue(source.contains(#"("SubagentStop", nil, "", "stopped"),"#))
    }
}
