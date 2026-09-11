//
//  ClaudeTurnTokensTests.swift
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

/// A Claude request's tokens: read from the transcript bytes after the turn's start offset (and
/// every subagent transcript), counted once per message, never from history copied into the file.
final class ClaudeTurnTokensTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-turn-tokens-\(UUID().uuidString)/.claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("p"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
    }

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One assistant record as Claude writes it (compact JSON, one line, newline-terminated).
    private func assistant(_ id: String, request: String = "req", at offset: TimeInterval = 5,
                           input: Int = 10, cacheRead: Int = 1000, output: Int = 20, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "parentUuid": "x", "isSidechain": false, "requestId": "\(request)-\(id)", "type": "assistant",
            "timestamp": Self.iso.string(from: start.addingTimeInterval(offset)),
            "message": ["id": "msg_\(id)", "model": "claude-opus-5", "role": "assistant",
                        "usage": ["input_tokens": input, "cache_creation_input_tokens": 0,
                                  "cache_read_input_tokens": cacheRead, "output_tokens": output]] as [String: Any],
        ]
        object.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    private func accumulator(offset: Int64 = 0) -> ClaudeTranscriptTokenAccumulator {
        ClaudeTranscriptTokenAccumulator(startOffset: offset, windowStart: start.addingTimeInterval(-60))
    }

    // MARK: - Usage line

    func testInputCountsCachedContextAndTheKeyIsMessagePlusRequest() throws {
        let record = try XCTUnwrap(ClaudeUsageLine.parse(assistant("a", input: 3, cacheRead: 5000, output: 40,
                                                                   extra: [:]).dropLast()))
        XCTAssertEqual(record.inputTokens, 3 + 5000)
        XCTAssertEqual(record.outputTokens, 40)
        XCTAssertEqual(record.dedupKey, "msg_a-req-a")
        XCTAssertNil(ClaudeUsageLine.parse(assistant("z", input: 0, cacheRead: 0, output: 0)), "zero usage is no record")
    }

    func testCodexShapedLinesStillParse() throws {
        // Codex puts usage at the top level and names the request `request_id`, with no fraction.
        let record = try XCTUnwrap(ClaudeUsageLine.parse(line([
            "timestamp": "2026-09-11T10:00:00Z", "model": "gpt-5", "request_id": "r1",
            "usage": ["input_tokens": 7, "output_tokens": 2],
        ]).dropLast()))
        XCTAssertEqual(record.inputTokens, 7)
        XCTAssertEqual(record.model, "gpt-5")
        XCTAssertEqual(record.dedupKey, "-r1")
    }

    // MARK: - Accumulator

    func testASplitMessageCountsOnce() {
        var acc = accumulator()
        acc.consume(assistant("a") + assistant("a") + assistant("b"))
        XCTAssertEqual(acc.input, 2 * 1010)
        XCTAssertEqual(acc.output, 40)
    }

    func testAPartialLineWaitsForItsNewline() {
        let record = assistant("a")
        var acc = accumulator()
        acc.consume(record.prefix(30))
        XCTAssertEqual(acc.output, 0)
        acc.consume(record.dropFirst(30))
        XCTAssertEqual(acc.output, 20)
        XCTAssertEqual(acc.readOffset, Int64(record.count))
    }

    func testOnlyAssistantRecordsCount() {
        var acc = accumulator()
        // A user record quoting the marker (escaped inside its string), and one carrying usage.
        acc.consume(line(["type": "user", "message": ["content": #"he wrote "type":"assistant" and "usage":{}"#],
                          "timestamp": Self.iso.string(from: start)]))
        acc.consume(line(["type": "user", "timestamp": Self.iso.string(from: start.addingTimeInterval(1)),
                          "message": ["usage": ["input_tokens": 99, "output_tokens": 99]]]))
        acc.consume(line(["type": "system", "subtype": "api_error"]))
        XCTAssertEqual(acc.input, 0)
        acc.consume(assistant("a"))
        XCTAssertEqual(acc.output, 20)
    }

    func testHistoryCopiedIntoTheFileIsNotThisRequest() {
        var acc = accumulator()
        acc.consume(assistant("old", at: -3600) + assistant("slack", at: -30) + assistant("new", at: 10))
        XCTAssertEqual(acc.output, 40, "an hour old is a resumed chat's history; half a minute is clock slack")
    }

    func testAReplacedOrShrunkFileIsReadAgainFromTheStart() {
        var acc = accumulator(offset: 100)
        XCTAssertEqual(acc.step(size: 500, fileID: 1), .read(from: 100, count: 400))
        acc.consume(Data(repeating: 0x20, count: 400))
        XCTAssertEqual(acc.step(size: 500, fileID: 1), .upToDate)
        XCTAssertEqual(acc.step(size: 800, fileID: 2), .read(from: 0, count: 800), "a new inode")
        acc.consume(Data(repeating: 0x20, count: 800))
        XCTAssertEqual(acc.step(size: 300, fileID: 2), .read(from: 0, count: 300), "shrank below what was read")
        var late = accumulator(offset: 1000)
        XCTAssertEqual(late.step(size: 200, fileID: 9), .read(from: 0, count: 200), "an offset past the end is a replaced file")
    }

    func testReadsAreChunked() {
        var acc = accumulator()
        XCTAssertEqual(acc.step(size: 10 << 20, fileID: 1), .read(from: 0, count: 4 << 20))
    }

    func testAnOverlongLineIsSkippedToItsNewline() {
        var acc = accumulator()
        acc.consume(Data(repeating: 0x41, count: (8 << 20) + 1))
        acc.consume(Data(repeating: 0x41, count: 100) + Data([0x0A]))
        acc.consume(assistant("after"))
        XCTAssertEqual(acc.output, 20)
    }

    func testTheSeenKeysAreBounded() {
        var acc = accumulator()
        var data = Data()
        for index in 0...ClaudeTranscriptTokenAccumulator.seenLimit { data.append(assistant("m\(index)", output: 1)) }
        acc.consume(data)
        acc.consume(assistant("m0", output: 1))
        XCTAssertEqual(acc.output, ClaudeTranscriptTokenAccumulator.seenLimit + 2,
                       "the oldest key is forgotten: split records are adjacent, so this never matters in practice")
        acc.consume(assistant("m\(ClaudeTranscriptTokenAccumulator.seenLimit)", output: 1))
        XCTAssertEqual(acc.output, ClaudeTranscriptTokenAccumulator.seenLimit + 2, "a recent key is still known")
    }

    // MARK: - Requests

    func testRequestsAreForVisibleClaudeCardsWithAFollowableTurn() {
        let home = "/Users/u"
        func card(_ id: String, provider: String = "claude", visible: Bool = true, path: String? = "/Users/u/.claude/projects/p/c.jsonl",
                  offset: Int64? = 10) -> AgentSessionStatus {
            var session = AgentSessionStatus(id: "\(provider)-\(id)", provider: provider, conversationID: id, chatName: nil,
                                             projectName: nil, rawState: "executing", displayState: .executing, updatedAt: start,
                                             isVisible: visible, executionStartedAt: nil)
            session.turn = HookTurn(startedAt: start, toolCalls: 1, transcriptPath: path, transcriptOffset: offset)
            return session
        }
        var turnless = card("t")
        turnless.turn = nil
        let requests = ClaudeTurnTokenRequest.requests(from: [
            card("a"), card("a"), card("b", provider: "cursor"), card("c", visible: false), card("d", offset: nil),
            card("e", path: "/Users/u/Documents/x.jsonl"), card("f", path: "/Volumes/x/.claude/projects/p/c.jsonl"), turnless,
        ], home: home)
        XCTAssertEqual(requests.map(\.conversationID), ["a"])
        XCTAssertEqual(requests.first?.subagentDirectory, "/Users/u/.claude/projects/p/c/subagents")
        XCTAssertEqual(requests.first?.windowStart, start.addingTimeInterval(-60))
    }

    // MARK: - Reader

    private func write(_ relative: String, _ data: Data) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }

    private func append(_ data: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func testTheMainTranscriptFromItsOffsetPlusEverySubagentLayout() throws {
        let before = assistant("before", at: 1)
        let main = try write("p/sess.jsonl", before + assistant("m1") + assistant("m2"))
        _ = try write("p/sess/subagents/agent-a1.jsonl", assistant("s1", output: 100))
        _ = try write("p/sess/subagents/workflows/wf_x/agent-a2.jsonl", assistant("s2", output: 1000))
        _ = try write("p/sess/subagents/notes.txt", Data("x".utf8))
        let reader = ClaudeTurnTokenReader(projectsRoot: root.path)
        let request = ClaudeTurnTokenRequest(conversationID: "sess", mainPath: main, startOffset: Int64(before.count),
                                             startedAt: start)
        let pass = reader.pass([request], now: start)
        XCTAssertFalse(pass.behind)
        XCTAssertEqual(pass.tokens["sess"]?.output, 20 + 20 + 100 + 1000, "the record before the offset is the last request's")
        XCTAssertEqual(pass.tokens["sess"]?.startOffset, Int64(before.count))
        try append(assistant("m3"), to: main)
        XCTAssertEqual(reader.pass([request], now: start).tokens["sess"]?.output, 1160, "an append is read next pass")
    }

    func testAChatIsReportedOnlyOnceCaughtUp() throws {
        var data = Data()
        for index in 0..<20 { data.append(assistant("m\(index)", output: 1)) }
        let main = try write("p/big.jsonl", data)
        let reader = ClaudeTurnTokenReader(projectsRoot: root.path)
        reader.passBudget = data.count / 3
        let request = ClaudeTurnTokenRequest(conversationID: "big", mainPath: main, startOffset: 0, startedAt: start)
        var passes = 0
        var last = reader.pass([request], now: start)
        while last.behind && passes < 10 {
            XCTAssertNil(last.tokens["big"], "no climbing totals while catching up")
            passes += 1
            last = reader.pass([request], now: start)
        }
        XCTAssertGreaterThan(passes, 0)
        XCTAssertEqual(last.tokens["big"]?.output, 20)
    }

    func testSymlinksAndFilesOutsideTheProjectsFolderAreNeverRead() throws {
        let real = try write("p/real.jsonl", assistant("a"))
        let link = root.appendingPathComponent("p/link.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("kannu-outside-\(UUID().uuidString).jsonl")
        try assistant("x").write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outLink = root.appendingPathComponent("p/out.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: outLink, withDestinationPath: outside.path)
        let reader = ClaudeTurnTokenReader(projectsRoot: root.path)
        for path in [link, outLink, outside.path] {
            let request = ClaudeTurnTokenRequest(conversationID: "c", mainPath: path, startOffset: 0, startedAt: start)
            XCTAssertNil(reader.pass([request], now: start).tokens["c"], path)
        }
        // A symlinked subagent file is not followed either.
        let main = try write("p/s2.jsonl", assistant("m"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("p/s2/subagents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("p/s2/subagents/agent-l.jsonl").path,
                                                   withDestinationPath: outside.path)
        let request = ClaudeTurnTokenRequest(conversationID: "s2", mainPath: main, startOffset: 0, startedAt: start)
        XCTAssertEqual(reader.pass([request], now: start).tokens["s2"]?.output, 20)
    }

    func testTooManySubagentFilesHideTheTotalRatherThanUndercount() throws {
        let main = try write("p/fan.jsonl", assistant("m"))
        for index in 0...ClaudeTurnTokenReader.subagentFileLimit {
            _ = try write("p/fan/subagents/agent-\(index).jsonl", Data())
        }
        let request = ClaudeTurnTokenRequest(conversationID: "fan", mainPath: main, startOffset: 0, startedAt: start)
        XCTAssertNil(ClaudeTurnTokenReader(projectsRoot: root.path).pass([request], now: start).tokens["fan"])
    }

    func testSubagentFilesLastWrittenBeforeTheTurnAreNotRead() throws {
        let main = try write("p/e.jsonl", assistant("m"))
        let old = try write("p/e/subagents/agent-old.jsonl", assistant("o", output: 500))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: old)
        let request = ClaudeTurnTokenRequest(conversationID: "e", mainPath: main, startOffset: 0, startedAt: start)
        XCTAssertEqual(ClaudeTurnTokenReader(projectsRoot: root.path).pass([request], now: start).tokens["e"]?.output, 20,
                       "a subagent of an earlier request")
    }
}
