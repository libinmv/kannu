//
//  ADRDetectionCommandTests.swift
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

/// The ADR Detection run as data (REGRESSIONS entry 8), the environment whitelist, and the
/// Kannu-owned adapter: embedded copy == mirror, and its transcript conversion.
final class ADRDetectionCommandTests: XCTestCase {
    private let checkout = URL(fileURLWithPath: "/Users/dev/ADR/Detection", isDirectory: true)
    private let adapter = URL(fileURLWithPath: "/Users/dev/.kannu/adr/detection/adr-analyze-session.py")
    private let transcript = URL(fileURLWithPath: "/Users/dev/.claude/projects/-Users-dev-proj/abc.jsonl")
    private let report = URL(fileURLWithPath: "/Users/dev/.kannu/adr/detection/abc.json")

    private static var mirrorURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/adr-analyze-session.py")
    }

    func testArgumentsRunOurAdapterInsideTheUsersProject() {
        var options = ADRDetectionCommand.Options()
        options.triageEnabled = true
        options.policy = false
        let args = ADRDetectionCommand.arguments(checkout: checkout, adapter: adapter, transcript: transcript, report: report, options: options)
        XCTAssertEqual(Array(args.prefix(5)), ["run", "--project", checkout.path, "python", adapter.path])
        XCTAssertEqual(args[args.firstIndex(of: "--transcript")! + 1], transcript.path)
        XCTAssertEqual(args[args.firstIndex(of: "--report")! + 1], report.path)
        XCTAssertEqual(args[args.firstIndex(of: "--triage")! + 1], "on")
        XCTAssertEqual(args[args.firstIndex(of: "--context")! + 1], "threat_intelligence,source_code")
        XCTAssertEqual(args[args.firstIndex(of: "--timeout")! + 1], "300")
        XCTAssertEqual(args[args.firstIndex(of: "--max-messages")! + 1], "400")
        XCTAssertTrue(ADRDetectionCommand.isValidAnalysis(arguments: args))
    }

    func testValidationRejectsAnythingButOurShape() {
        let good = ADRDetectionCommand.arguments(checkout: checkout, adapter: adapter, transcript: transcript, report: report, options: .init())
        XCTAssertFalse(ADRDetectionCommand.isValidAnalysis(arguments: good + ["--dangerously-skip-permissions"]), "permission flags never pass through Kannu")
        XCTAssertFalse(ADRDetectionCommand.isValidAnalysis(arguments: good + ["--allowedTools", "Bash"]))
        var wrongAdapter = good; wrongAdapter[4] = "/Users/dev/other.py"
        XCTAssertFalse(ADRDetectionCommand.isValidAnalysis(arguments: wrongAdapter))
        XCTAssertFalse(ADRDetectionCommand.isValidAnalysis(arguments: good.filter { $0 != "--report" }))
        XCTAssertFalse(ADRDetectionCommand.isValidAnalysis(arguments: ["run", "--project", checkout.path, "python", adapter.path]))
    }

    func testEnvironmentIsAWhitelistNotTheInheritedOne() {
        let none = ADRDetectionCommand.environment(openAIKey: nil, anthropicKey: nil, path: "/opt/homebrew/bin:/usr/bin", home: "/Users/dev")
        XCTAssertEqual(Set(none.keys), ["PATH", "HOME", "LANG"])
        let both = ADRDetectionCommand.environment(openAIKey: " sk-test ", anthropicKey: "ant-test", path: "/usr/bin", home: "/Users/dev")
        XCTAssertEqual(both["OPENAI_API_KEY"], "sk-test", "trimmed")
        XCTAssertEqual(both["ANTHROPIC_API_KEY"], "ant-test")
        XCTAssertNil(ADRDetectionCommand.environment(openAIKey: "", anthropicKey: "   ", path: "/usr/bin", home: "/")["OPENAI_API_KEY"])
        XCTAssertEqual(ADRDetectionCommand.processTimeout(forReasoningTimeout: 300), 420)
        XCTAssertTrue(ADRDetectionCommand.producedVerdict(exitStatus: 0))
        XCTAssertFalse(ADRDetectionCommand.producedVerdict(exitStatus: 6))
    }

    func testEmbeddedAdapterMatchesTheMirror() throws {
        let mirror = try String(contentsOf: Self.mirrorURL, encoding: .utf8)
        XCTAssertEqual(ADRDetectionCommand.adapterSource, mirror, "scripts/adr-analyze-session.py must equal ADRDetectionCommand.adapterSource")
        XCTAssertTrue(mirror.contains(ADRDetectionCommand.adapterVersionMarker))
    }

    func testAdapterConvertsAClaudeTranscriptLikeUpstream() throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(python == nil, "python3 not available")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kannu-adr-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonl = dir.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"fix the bug"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"a.swift"}]}]}}"#,
            #"{"type":"ai-title","aiTitle":"Fix"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python!)
        process.arguments = [Self.mirrorURL.path, "--transcript", jsonl.path, "--convert-only", "--max-messages", "10"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "tool", "assistant"])
        XCTAssertEqual(messages[1]["content"], "Looking. [TOOL_USE: Bash (id: t1)]")
        XCTAssertEqual(messages[2]["content"], "a.swift")
        XCTAssertEqual(messages[3]["content"], "Done.")
    }
}
