//
//  AgentTurnFormatTests.swift
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

/// What a Recent chats row shows beside the light: "1h 53m 54s" / "212 tools · 1.4M in · 45k out",
/// and "Ran …" once the request ended.
final class AgentTurnFormatTests: XCTestCase {
    typealias F = AgentTurnFormat
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    func testDurations() {
        XCTAssertEqual(F.duration(0), "0s")
        XCTAssertEqual(F.duration(42.9), "42s")
        XCTAssertEqual(F.duration(204), "3m 24s")
        XCTAssertEqual(F.duration(3600), "1h 0m 0s")
        XCTAssertEqual(F.duration(6834), "1h 53m 54s")
        XCTAssertEqual(F.duration(-5), "0s")
        XCTAssertEqual(F.shortDuration(6834), "1h 53m")
        XCTAssertEqual(F.shortDuration(204), "3m")
        XCTAssertEqual(F.shortDuration(42), "42s")
        XCTAssertEqual(F.ran(F.duration(7392)), "Ran 2h 3m 12s")
    }

    func testToolCalls() {
        XCTAssertNil(F.tools(0))
        XCTAssertEqual(F.tools(1), "1 tool")
        XCTAssertEqual(F.tools(212), "212 tools")
    }

    func testCompactNumbersRollIntoTheNextUnit() {
        let cases: [(Int, String)] = [
            (-3, "0"), (0, "0"), (812, "812"), (999, "999"), (1000, "1k"), (4000, "4k"), (4500, "4.5k"),
            (9949, "9.9k"), (9960, "10k"), (45_000, "45k"), (999_499, "999k"), (999_600, "1M"),
            (1_400_000, "1.4M"), (9_960_000, "10M"), (65_000_000, "65M"), (1_200_000_000, "1.2B"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(F.compact(value), text, "\(value)")
        }
    }

    func testTheSecondLineFallsBackWidestFirst() {
        let tokens = TurnTokens(startedAt: t0, startOffset: 0, input: 1_400_000, output: 45_000)
        XCTAssertEqual(F.tokens(tokens), "1.4M in · 45k out")
        let both = F.metricsLines(toolCalls: 212, tokens: tokens)
        XCTAssertEqual(both.full, "212 tools · 1.4M in · 45k out")
        XCTAssertEqual(both.tokensOnly, "1.4M in · 45k out")
        XCTAssertEqual(both.toolsOnly, "212 tools")
        let tokensAlone = F.metricsLines(toolCalls: 0, tokens: tokens)
        XCTAssertEqual(tokensAlone.full, "1.4M in · 45k out")
        XCTAssertNil(tokensAlone.tokensOnly, "never the same line twice")
        XCTAssertNil(tokensAlone.toolsOnly)
        let toolsAlone = F.metricsLines(toolCalls: 3, tokens: nil)
        XCTAssertEqual(toolsAlone.full, "3 tools")
        XCTAssertNil(toolsAlone.tokensOnly)
        XCTAssertNil(toolsAlone.toolsOnly)
        let nothing = F.metricsLines(toolCalls: 0, tokens: nil)
        XCTAssertNil(nothing.full, "no empty line")
    }

    func testTheSpokenFormSpellsTheUnits() {
        XCTAssertEqual(F.spokenCount(812), "812")
        XCTAssertEqual(F.spokenCount(45_000), "45 thousand")
        XCTAssertEqual(F.spokenCount(1_400_000), "1.4 million")
        XCTAssertEqual(F.spokenCount(2_000_000_000), "2 billion")
        let tokens = TurnTokens(startedAt: t0, startOffset: 0, input: 1_400_000, output: 45_000)
        let spoken = F.accessibilityText(.ended(7392), now: t0, toolCalls: 212, tokens: tokens)
        XCTAssertTrue(spoken.hasPrefix("Ran for "), spoken)
        XCTAssertTrue(spoken.contains("212 tool calls"), spoken)
        XCTAssertTrue(spoken.hasSuffix("1.4 million tokens in, 45 thousand out"), spoken)
        XCTAssertTrue(F.accessibilityText(.live(since: t0), now: t0.addingTimeInterval(65), toolCalls: 1, tokens: nil)
            .contains("1 tool call"))
    }

    // MARK: - Which time a card shows

    private func turn(ended: TimeInterval? = nil) -> HookTurn {
        HookTurn(startedAt: t0, endedAt: ended.map { t0.addingTimeInterval($0) }, toolCalls: 5)
    }

    private func display(_ turn: HookTurn?, _ state: AgentTrafficLightState, working: Bool = false,
                         updated: TimeInterval = 0, started: Date? = nil) -> AgentTurnDisplay? {
        AgentTurnDisplay.duration(turn: turn, executionStartedAt: started, state: state, hookReportsWork: working,
                                  updatedAt: t0.addingTimeInterval(updated))
    }

    func testAnOpenTurnTicksFromThePromptWhileRunningOrWaiting() {
        XCTAssertEqual(display(turn(), .executing), .live(since: t0))
        XCTAssertEqual(display(turn(), .thinking), .live(since: t0))
        XCTAssertEqual(display(turn(), .awaitingInput), .live(since: t0), "a prompt is part of the request")
        XCTAssertNil(display(turn(), .stopped), "stopped without a Stop (Esc, killed): no time rather than a wrong one")
        XCTAssertNil(display(turn(), .inactive))
    }

    func testAnEndedTurnShowsHowLongItRan() {
        XCTAssertEqual(display(turn(ended: 7392), .stopped, updated: 7392), .ended(7392))
        XCTAssertEqual(display(turn(ended: 7392), .awaitingInput, updated: 7452), .ended(7392),
                       "the idle notice's yellow afterwards is not work")
        XCTAssertEqual(display(turn(ended: 100), .thinking, working: true, updated: 101), .ended(100),
                       "a late completion lands within two seconds")
    }

    func testWorkReportedLongAfterTheEndIsStillTheRequest() {
        XCTAssertEqual(display(turn(ended: 100), .executing, working: true, updated: 160), .live(since: t0))
    }

    func testWithoutATurnTheInMemoryStartIsUsedOnlyWhileRunning() {
        let started = t0.addingTimeInterval(-204)
        XCTAssertEqual(display(nil, .executing, started: started), .live(since: started))
        XCTAssertNil(display(nil, .stopped, started: started))
        XCTAssertNil(display(nil, .executing))
    }
}
