import XCTest

final class AgentSessionLogParserTests: XCTestCase {
    private typealias Result = AgentSessionLogParser.ClaudeTailResult

    private func line(_ json: String) -> String { json + "\n" }

    // MARK: - user records

    func testTrailingUserPromptIsWorking() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.123Z","message":{"role":"user","content":"fix the bug"}}"#)
        let result = AgentSessionLogParser.claudeTailState(fromTailText: text)
        XCTAssertEqual(result.state, .working)
        XCTAssertNotNil(result.recordTimestamp)
    }

    func testTimestampWithoutFractionalSecondsParses() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00Z","message":{"role":"user","content":"hello"}}"#)
        let result = AgentSessionLogParser.claudeTailState(fromTailText: text)
        XCTAssertEqual(result.state, .working)
        XCTAssertNotNil(result.recordTimestamp)
    }

    func testInterruptRecordIsTurnFinished() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testToolUseInterruptRecordIsTurnFinished() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testInterruptAsPlainStringContentIsTurnFinished() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":"[Request interrupted by user]"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testInterruptInsideToolResultIsTurnFinished() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}]}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testNormalToolResultIsWorking() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok, 3 files changed"}]}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .working)
    }

    // MARK: - assistant records

    func testAssistantToolUseIsToolInFlight() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .toolInFlight)
    }

    func testEndTurnIsTurnFinished() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testStopSequenceIsTurnFinished() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"stop_sequence"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testMaxTokensIsTurnFinished() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"truncat"}],"stop_reason":"max_tokens"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testRefusalIsTurnFinished() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"no"}],"stop_reason":"refusal"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testToolUseStopReasonTextRecordIsWorking() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"let me check"}],"stop_reason":"tool_use"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .working)
    }

    func testNullStopReasonIsWorking() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"thinking..."}],"stop_reason":null}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .working)
    }

    // MARK: - bookkeeping and truncation

    func testBookkeepingAfterEndTurnIsStillTurnFinished() {
        let text = line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#)
            + line(#"{"type":"ai-title","title":"Fix healthcheck"}"#)
            + line(#"{"type":"custom-title","title":"my session"}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testTruncatedLeadingFragmentIsSkipped() {
        let text = #"ncated tail of a giant record"}]}}"# + "\n"
            + line(#"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#)
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .turnFinished)
    }

    func testFragmentOnlyTextIsUnknown() {
        let text = #"ncated tail with no complete records"# + "\n"
        XCTAssertEqual(AgentSessionLogParser.claudeTailState(fromTailText: text).state, .unknown)
    }

    func testInterruptTimestampIsReturned() {
        let text = line(#"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)
            + line(#"{"type":"ai-title","title":"whatever"}"#)
        let result = AgentSessionLogParser.claudeTailState(fromTailText: text)
        XCTAssertEqual(result.state, .turnFinished)
        let expected = ISO8601DateFormatter().date(from: "2026-08-21T10:00:00Z")
        XCTAssertEqual(result.recordTimestamp, expected)
    }

    // MARK: - file wrapper escalation

    func testEscalationFindsVerdictBeyondFirstWindow() throws {
        // A final record much larger than the 16 KB first window: the wrapper must widen
        // the window instead of settling for .unknown.
        let bigText = String(repeating: "x", count: 40_000)
        let content = #"{"type":"assistant","timestamp":"2026-08-21T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":""# + bigText + #""}],"stop_reason":"end_turn"}}"# + "\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        try content.data(using: .utf8)!.write(to: url)

        XCTAssertEqual(AgentSessionLogParser.claudeTailState(at: url).state, .turnFinished)
    }
}
