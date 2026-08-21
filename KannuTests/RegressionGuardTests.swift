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
