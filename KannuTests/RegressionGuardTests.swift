import XCTest

/// Tests that exist purely to pin invariants which have broken more than once.
///
/// Each one names the regression it guards and cites the commits, so a future reader who
/// finds a test inconvenient can see the cost of removing it. See docs/REGRESSIONS.md.
final class RegressionGuardTests: XCTestCase {

    // MARK: - Active-state staleness window

    /// Hook-only providers (Codex, VS Code, Antigravity) write NO status file during a tool
    /// call — the file goes quiet for the tool's whole duration. So the active-state window
    /// must exceed the longest plausible tool call.
    ///
    /// Regression history: set to 360s at 511e33b, dropped to 15s by 709457e ("green light
    /// lingering during idle time"), restored to 360s by 817f114 after CodeRabbit caught it.
    /// Shortening this converts a false-green complaint into a false-RED bug for every
    /// provider without a live status channel.
    func testHookOnlyProviderMidToolCallStaysActiveAtTwoMinutes() {
        let resolved = AgentTrafficLightMapper.resolveHookState(
            rawState: "executing",
            ageMs: 120_000, // two minutes into a tool call, no status write
            collapseMs: 5_000,
            inactiveMs: 5_000
        )
        XCTAssertTrue(
            resolved.state.isActiveRun,
            "A hook-only provider two minutes into a tool call must still read as active. "
                + "If this fails, the active-state staleness default was shortened again — see 709457e."
        )
        XCTAssertTrue(resolved.visible)
    }

    /// The same window at five minutes — still inside the 360s budget.
    func testHookOnlyProviderMidToolCallStaysActiveAtFiveMinutes() {
        let resolved = AgentTrafficLightMapper.resolveHookState(
            rawState: "executing",
            ageMs: 300_000,
            collapseMs: 5_000,
            inactiveMs: 5_000
        )
        XCTAssertTrue(resolved.state.isActiveRun, "Five minutes is still within the 360s active window.")
    }

    // MARK: - Entry 12: yellow follows evidence, not the clock

    /// An unanswered prompt whose session is provably still waiting keeps its yellow however
    /// long it sits. The 300 s window is only the fallback for waits nothing can corroborate.
    func testHeldAwaitingInputStaysYellowAtOneHour() {
        let resolved = AgentTrafficLightMapper.resolveHookState(
            rawState: "awaiting_input", ageMs: 3_600_000, collapseMs: 5_000, inactiveMs: 5_000,
            holdAwaitingInput: true
        )
        XCTAssertEqual(resolved.state, .awaitingInput)
        XCTAssertTrue(resolved.visible)
    }

    func testUnheldAwaitingInputExpiresAfterFiveMinutes() {
        let inside = AgentTrafficLightMapper.resolveHookState(
            rawState: "awaiting_input", ageMs: 300_000, collapseMs: 5_000, inactiveMs: 5_000)
        XCTAssertEqual(inside.state, .awaitingInput)
        XCTAssertTrue(inside.visible)
        let past = AgentTrafficLightMapper.resolveHookState(
            rawState: "awaiting_input", ageMs: 300_001, collapseMs: 5_000, inactiveMs: 5_000)
        XCTAssertEqual(past.state, .inactive, "Claude idle_prompt, a dead process, Cursor's sticky yellow: the clock still rules")
        XCTAssertFalse(past.visible)
    }

    func testAwaitingInputHoldFollowsEvidencePerProvider() {
        typealias M = AgentTrafficLightMapper
        XCTAssertTrue(M.holdsAwaitingInput(provider: "claude", processAlive: true, tail: .toolInFlight, cursorPendingApproval: false))
        for tail: AgentSessionLogParser.ClaudeTailState? in [.working, .turnFinished, .unknown, nil] {
            XCTAssertFalse(M.holdsAwaitingInput(provider: "claude", processAlive: true, tail: tail, cursorPendingApproval: true),
                           "a live Claude with no outstanding tool_use is not waiting on a prompt")
        }
        XCTAssertFalse(M.holdsAwaitingInput(provider: "claude", processAlive: false, tail: .toolInFlight, cursorPendingApproval: false))
        XCTAssertTrue(M.holdsAwaitingInput(provider: "cursor", processAlive: false, tail: nil, cursorPendingApproval: true))
        XCTAssertFalse(M.holdsAwaitingInput(provider: "cursor", processAlive: false, tail: nil, cursorPendingApproval: false))
        for provider in ["vscode", "codex", "antigravity", "copilot", "gemini", "qwen", "opencode"] {
            XCTAssertTrue(M.holdsAwaitingInput(provider: provider, processAlive: false, tail: nil, cursorPendingApproval: false),
                          "\(provider): nothing can corroborate or refute; the stale cap ends it")
        }
        for provider in ["warp", "claudedesktop", "unknown"] {
            XCTAssertFalse(M.holdsAwaitingInput(provider: provider, processAlive: true, tail: .toolInFlight, cursorPendingApproval: true))
        }
        XCTAssertTrue(M.isAwaitingInputRawState("awaiting_input"))
        XCTAssertTrue(M.isAwaitingInputRawState("AwaitingInput"))
        XCTAssertFalse(M.isAwaitingInputRawState("executing"))
    }

    func testOnlyACorroboratedClaudePromptOutlivesTheStaleCap() {
        typealias M = AgentTrafficLightMapper
        XCTAssertTrue(M.awaitingInputOutlivesStaleCap(provider: "claude", processAlive: true, tail: .toolInFlight))
        XCTAssertFalse(M.awaitingInputOutlivesStaleCap(provider: "claude", processAlive: false, tail: .toolInFlight))
        XCTAssertFalse(M.awaitingInputOutlivesStaleCap(provider: "claude", processAlive: true, tail: .turnFinished))
        XCTAssertFalse(M.awaitingInputOutlivesStaleCap(provider: "cursor", processAlive: true, tail: .toolInFlight))
        XCTAssertFalse(M.awaitingInputOutlivesStaleCap(provider: "vscode", processAlive: true, tail: .toolInFlight),
                       "hook-only providers keep the cap: it is the end of their yellow")
    }

    /// A Claude chat is silent for a whole workflow or a long Bash call; deleting its file at the
    /// 30-minute cap lost the request's turn (hook v39). Kept only while work is provably real;
    /// never a stopped file, never another provider (their cap is the end of their card).
    func testOnlyProvablyLiveClaudeWorkOutlivesTheStaleCap() {
        typealias M = AgentTrafficLightMapper
        func keeps(_ provider: String = "claude", _ raw: String = "executing", alive: Bool = false,
                   named: Bool = false, subOfOpenTurn: Bool = false) -> Bool {
            M.hookFileOutlivesStaleCap(provider: provider, rawState: raw, processAlive: alive,
                                       namedByFreshSubagent: named, subagentOfOpenTurn: subOfOpenTurn)
        }
        XCTAssertTrue(keeps(alive: true))
        XCTAssertTrue(keeps("claude", "thinking", alive: true))
        XCTAssertTrue(keeps(named: true), "a subagent written within the cap proves the chat is working")
        XCTAssertTrue(keeps("claude", "thinking", subOfOpenTurn: true), "a subagent of the open turn keeps its count")
        XCTAssertFalse(keeps(), "no evidence: the cap applies")
        XCTAssertFalse(keeps("claude", "stopped", alive: true, named: true, subOfOpenTurn: true),
                       "a stopped file would shadow the passive card")
        XCTAssertFalse(keeps("claude", "awaiting_input", alive: true), "yellow has its own rule (entry 12)")
        XCTAssertFalse(keeps("cursor", "executing", alive: true, named: true))
        XCTAssertFalse(keeps("codex", "executing", alive: true))
    }

    /// Entry 10: a subagent's tool call only moves its chat's count. That publishes the list but
    /// must not bump the reveal pulse, or the island never collapses while a workflow runs.
    func testATurnOnlyChangeIsNoRevealPulse() {
        typealias M = AgentTrafficLightMapper
        var before = AgentSessionStatus(id: "claude-c", provider: "claude", conversationID: "c", chatName: "Chat",
                                        projectName: "kannu", rawState: "executing", displayState: .executing,
                                        updatedAt: Date(timeIntervalSince1970: 1_000), isVisible: true, executionStartedAt: nil)
        before.turn = HookTurn(startedAt: Date(timeIntervalSince1970: 900), toolCalls: 4)
        var counted = before
        counted.turn?.toolCalls = 5
        XCTAssertNotEqual([before], [counted], "the list still publishes")
        XCTAssertFalse(M.pulseRelevantChange(from: [before], to: [counted]))
        let moved = before.withDisplayState(.awaitingInput, visible: true)
        XCTAssertTrue(M.pulseRelevantChange(from: [before], to: [moved]))
        XCTAssertTrue(M.pulseRelevantChange(from: [before], to: [before, counted]), "a card appearing is news")
        XCTAssertFalse(M.pulseRelevantChange(from: [before], to: [before]))
    }

    // MARK: - Chat-name sanitation

    /// A tool name must never survive as a chat title. Chat-name resolution has regressed
    /// five times (04ec047, ae6151f, e6d9abb, 8caf98d, f46a323) — most memorably when both
    /// resolvers compared a log-derived title against itself and therefore rejected every
    /// real title, and when sessions rendered as "Untitled chat".
    ///
    /// The resolvers themselves live on CursorAgentStatusMonitor and are `private`, so they
    /// are not reachable from this logic-only target (noted as a gap in docs/REGRESSIONS.md).
    /// This pins the shared primitive both of them depend on.
    func testToolNamesAreRejectedAsChatTitles() {
        let toolNames = [
            "shell", "Shell", "run_terminal_cmd", "runTerminalCmd",
            "read", "write", "edit", "grep", "glob", "task",
            "todowrite", "apply_patch", "str_replace", "web_search", "webfetch",
            "AskQuestion", "subagent"
        ]
        for name in toolNames {
            XCTAssertTrue(
                AgentApprovalGatedTools.looksLikeToolName(name),
                "\(name) is a tool name and must not be shown as a chat title."
            )
        }
    }

    /// The other half of the invariant: real titles must survive. A over-broad matcher here
    /// is how sessions ended up as "Untitled chat".
    func testRealChatTitlesSurviveSanitation() {
        let realTitles = [
            "Fix the notch traffic light",
            "Reading the parser",
            "Debugging a shell script",   // contains a tool word, but is a sentence
            "Kannu release checklist",
            "Why does the light stay green?"
        ]
        for title in realTitles {
            XCTAssertFalse(
                AgentApprovalGatedTools.looksLikeToolName(title),
                "\(title) is a real chat title and must not be discarded as a tool name."
            )
        }
    }

    func testEmptyAndWhitespaceTitlesAreNotToolNames() {
        XCTAssertFalse(AgentApprovalGatedTools.looksLikeToolName(nil))
        XCTAssertFalse(AgentApprovalGatedTools.looksLikeToolName(""))
        XCTAssertFalse(AgentApprovalGatedTools.looksLikeToolName("   "))
    }
}
