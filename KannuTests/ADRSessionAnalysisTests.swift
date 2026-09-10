//
//  ADRSessionAnalysisTests.swift
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

/// The adapter's verdict JSON → a record, and a malicious record → a finding.
final class ADRSessionAnalysisTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func parse(_ json: String) throws -> ADRSessionAnalysis {
        try ADRSessionAnalysis.parse(Data(json.utf8), conversationID: "conv-1", chatName: "Fix the parser", reportPath: "/tmp/r.json", now: t0)
    }

    func testVerdictParses() throws {
        let a = try parse(#"{"schema":1,"is_malicious":true,"confidence":0.91,"tactic":"permission_abuse","explanation":"Ran sudo after reading an issue.","threat_messages":3,"total_messages":40,"method":"adr","model_used":"claude-sonnet-4-6","input_tokens":12000,"output_tokens":900,"cost_usd":0.05,"triage":"on"}"#)
        XCTAssertTrue(a.isMalicious)
        XCTAssertEqual(a.confidence, 0.91)
        XCTAssertEqual(a.tactic, "permission_abuse")
        XCTAssertEqual(a.threatMessages, 3)
        XCTAssertEqual(a.costUSD, 0.05)
        XCTAssertTrue(a.triageEnabled)
        XCTAssertEqual(a.shortLabel, "permission abuse · 0.91")
    }

    func testAdapterErrorsAreSurfacedNotTurnedIntoVerdicts() {
        XCTAssertThrowsError(try parse(#"{"schema":1,"error":"cannot import ADR Detection: No module named guardrail"}"#)) { error in
            XCTAssertEqual(error as? ADRSessionAnalysis.ParseError, .adapterError("cannot import ADR Detection: No module named guardrail"))
        }
        XCTAssertThrowsError(try parse(#"{"schema":2,"is_malicious":false}"#))
        XCTAssertThrowsError(try parse("not json"))
    }

    func testOnlyAMaliciousVerdictBecomesAFinding() throws {
        let clean = try parse(#"{"schema":1,"is_malicious":false,"confidence":0.08,"explanation":"Routine refactor.","triage":"off"}"#)
        XCTAssertNil(clean.finding())
        XCTAssertEqual(clean.shortLabel, "clean · 0.08")

        let confident = try parse(#"{"schema":1,"is_malicious":true,"confidence":0.91,"tactic":"reasoning_data_manipulation","explanation":"Hidden instructions in a fetched page changed the task.","threat_messages":2,"total_messages":30,"model_used":"claude-sonnet-4-6"}"#)
        let high = try XCTUnwrap(confident.finding())
        XCTAssertEqual(high.severity, .high)
        XCTAssertEqual(high.source, .detection)
        XCTAssertEqual(high.rule, "detection_reasoning_data_manipulation")
        XCTAssertEqual(high.title, "Prompt or data manipulation in this chat")
        XCTAssertEqual(high.sessionID, "conv-1")
        XCTAssertEqual(high.assetName, "Fix the parser")
        XCTAssertEqual(high.evidence, ["confidence 0.91", "2 of 30 messages flagged", "model claude-sonnet-4-6"])
        XCTAssertEqual(high.firstSeen, t0)
        XCTAssertEqual(high.id, confident.finding()?.id, "same verdict, same id")

        let unsure = try parse(#"{"schema":1,"is_malicious":true,"confidence":0.6,"explanation":"Maybe."}"#)
        let medium = try XCTUnwrap(unsure.finding(existingFirstSeen: t0.addingTimeInterval(-100)))
        XCTAssertEqual(medium.severity, .medium)
        XCTAssertEqual(medium.title, "Malicious activity in this chat")
        XCTAssertEqual(medium.firstSeen, t0.addingTimeInterval(-100), "an existing finding keeps its first-seen")
    }

    func testTacticTitles() {
        XCTAssertEqual(ADRSessionAnalysis.title(forTactic: "initial_compromise"), "Initial compromise attempt in this chat")
        XCTAssertEqual(ADRSessionAnalysis.title(forTactic: "operational_impact"), "Harmful operational impact in this chat")
        XCTAssertEqual(ADRSessionAnalysis.title(forTactic: "novel_thing"), "Novel thing in this chat")
        XCTAssertEqual(ADRSessionAnalysis.title(forTactic: nil), "Malicious activity in this chat")
    }
}
