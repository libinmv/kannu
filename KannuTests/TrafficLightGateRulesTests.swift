//
//  TrafficLightGateRulesTests.swift
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

/// The monitor and the notch are views, not in the logic target, so their wiring is read from
/// source (the `TimerNamingRulesTests` idiom). What is pinned, and why it must not drift:
///
/// 1. The monitor's one publish point routes through `TrafficLightPersistenceGate`, and a held
///    publish re-evaluates by *rescanning* — publishing a pair captured when the hold was armed
///    would reintroduce the race the gate exists to close (the state may have changed while the
///    hold slept).
/// 2. `stop()` cancels the hold task and resets the gate, so a restart never inherits a stale
///    hold or compares against a torn-down published pair.
/// 3. The notch re-arms its reveal windows only when the *published* light changed. Re-arming on
///    every activity pulse pinned the island out for as long as a chat stayed green — the bug
///    this work removes.
final class TrafficLightGateRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func body(of function: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: function), "\(function) not found")
        let open = try XCTUnwrap(text.range(of: "{", range: start.upperBound..<text.endIndex))
        var depth = 0
        var index = open.lowerBound
        repeat {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1 }
            index = text.index(after: index)
        } while index < text.endIndex && depth > 0
        return String(text[start.lowerBound..<index])
    }

    func testThePublishPointRoutesThroughTheGateAndHoldsRescanFresh() throws {
        let monitor = Self.code(try Self.source("Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift"))
        let publish = try Self.body(of: "private func publishTrafficLight(", in: monitor)
        XCTAssertTrue(publish.contains("persistenceGate.decide("),
                      "publishTrafficLight no longer consults the persistence gate")
        let holdStart = try XCTUnwrap(publish.range(of: "case .hold(let until):"), "no hold case")
        let holdEnd = try XCTUnwrap(publish.range(of: "case .publish:", range: holdStart.upperBound..<publish.endIndex),
                                    "the publish case must follow the hold case")
        let hold = String(publish[holdStart.lowerBound..<holdEnd.lowerBound])
        XCTAssertTrue(hold.contains("scheduleRescan("), """
        the hold path must re-evaluate by rescanning — the freshest disk state decides, \
        never a pair captured when the hold was armed
        """)
        for write in ["trafficLightState =", "shouldShowTrafficLight ="] {
            XCTAssertFalse(hold.contains(write), "the hold path publishes nothing itself (found \(write))")
        }
    }

    func testStopCancelsTheHoldAndResetsTheGate() throws {
        let monitor = Self.code(try Self.source("Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift"))
        let stop = try Self.body(of: "func stop()", in: monitor)
        XCTAssertTrue(stop.contains("gateHoldTask?.cancel()"), "stop() leaves the hold task running")
        XCTAssertTrue(stop.contains("persistenceGate.reset()"), "stop() leaves the gate's published pair behind")
    }

    func testTheRevealReArmsOnlyWhenThePublishedLightChanged() throws {
        let contentView = Self.code(try Self.source("Kannu/ContentView.swift"))
        let note = try Self.body(of: "private func noteAgentActivityPulse()", in: contentView)
        XCTAssertTrue(note.contains("lastRevealedLightState"), """
        noteAgentActivityPulse re-arms without comparing against the last published light — \
        every hook write of a green chat would pin the island out again
        """)
        XCTAssertTrue(note.contains("consumeActivityPulseWasHeartbeatOnly"),
                      "the heartbeat fast-path (entry 10's latch) must stay first")
    }
}
