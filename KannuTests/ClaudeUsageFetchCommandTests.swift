import XCTest

/// Guards the two shipped regressions where a "harmless" addition to the usage spawn silently broke
/// the fetch. Both looked healthy at runtime — session started, spinner ran, nothing fetched — so
/// only a pinned test catches them. See docs/REGRESSIONS.md.
final class ClaudeUsageFetchCommandTests: XCTestCase {

    // MARK: - Regression 1: print-only flags kill the interactive session

    func testNoAttemptUsesAPrintOnlyFlag() {
        for arguments in ClaudeUsageFetchCommand.attempts {
            XCTAssertTrue(
                ClaudeUsageFetchCommand.isValidForInteractiveSession(arguments: arguments),
                "Attempt \(arguments) carries a print-only flag. /usage needs an interactive session, "
                + "and the CLI exits immediately on these — the session dies before /usage is typed."
            )
        }
    }

    func testNoSessionPersistenceIsRejected() {
        // The exact flag that shipped broken: "can only be used with --print mode".
        XCTAssertFalse(ClaudeUsageFetchCommand.isValidForInteractiveSession(
            arguments: ["--no-session-persistence"]))
        XCTAssertFalse(ClaudeUsageFetchCommand.isValidForInteractiveSession(
            arguments: ["--settings", "{}", "--no-session-persistence"]))
    }

    func testPlainArgumentsAreValid() {
        XCTAssertTrue(ClaudeUsageFetchCommand.isValidForInteractiveSession(arguments: []))
        XCTAssertTrue(ClaudeUsageFetchCommand.isValidForInteractiveSession(
            arguments: ["--settings", #"{"disableRemoteControl":true}"#]))
    }

    // MARK: - Regression 2: the env var that silenced the fetch

    func testEnvironmentIsPlainInheritance() {
        // nil means "inherit", which is what the version that actually fetched did. Setting
        // CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC suppressed the /api/oauth/usage call itself.
        XCTAssertNil(ClaudeUsageFetchCommand.environment(),
                     "The fetch must inherit the environment. Adding variables here broke it once.")
    }

    func testTheBreakingEnvironmentKeyIsRecordedAsForbidden() {
        XCTAssertTrue(ClaudeUsageFetchCommand.forbiddenEnvironmentKeys
            .contains("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"))
    }

    // MARK: - The proven fallback must survive

    func testLastAttemptIsBare() {
        // The bare invocation is the one observed to actually fetch. If a future change "improves"
        // it away, the button silently stops working again.
        XCTAssertEqual(ClaudeUsageFetchCommand.attempts.last, [],
                       "The final attempt must be the bare invocation proven to fetch.")
    }

    func testAttemptsAreOrderedCleanestFirst() {
        XCTAssertEqual(ClaudeUsageFetchCommand.attempts.count, 2)
        XCTAssertTrue(ClaudeUsageFetchCommand.attempts[0].contains("--settings"),
                      "The first attempt should try to suppress the device registration.")
    }
}
